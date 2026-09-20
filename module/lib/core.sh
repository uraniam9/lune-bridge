#!/system/bin/sh
#
# Lune Bridge - shared runtime.
#
# Sourced by lunectl, luned, lune-probe and the module's boot scripts. Targets
# mksh + toybox, which is what /system/bin/sh actually is on a modern Android.
# That means: no bashisms, no arrays, and no floating point anywhere - every
# calculation below is fixed-point integer arithmetic in permille.

LUNE_DIR=/data/adb/lune
LUNE_CONF=$LUNE_DIR/config
LUNE_CAPS=$LUNE_DIR/caps
LUNE_LOG=$LUNE_DIR/log
LUNE_BOOT_GUARD=$LUNE_DIR/boot-pending
LUNE_MODDIR=${LUNE_MODDIR:-/data/adb/modules/lune_bridge}

# AOSP's reduce-bright-colors ramp is (1 - 0.9556*strength). Kept in permille
# so the dim maths stays in integers.
RBC_SLOPE_PERMILLE=956

# Below this backlight percentage most PWM-dimmed OLED panels start flickering
# hard enough to be felt. Only a default: a device profile or the user's own
# measurement overrides it, because the real knee is panel-specific.
DEFAULT_PWM_KNEE_PCT=50

umask 077

log() {
    # Keep the log small enough that it never becomes the reason /data fills up.
    if [ -f "$LUNE_LOG" ] && [ "$(stat -c %s "$LUNE_LOG" 2>/dev/null || echo 0)" -gt 131072 ]; then
        tail -n 200 "$LUNE_LOG" > "$LUNE_LOG.trim" 2>/dev/null && mv "$LUNE_LOG.trim" "$LUNE_LOG"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LUNE_LOG" 2>/dev/null
}

die() {
    echo "lune: $*" >&2
    log "ERROR $*"
    exit 1
}

# ---------------------------------------------------------------------------
# key=value stores
#
# Deliberately not JSON: there is no jq on a stock Android, and shell-parsing
# JSON correctly is worse than not using it.
# ---------------------------------------------------------------------------

kv_get() {
    # kv_get <file> <key> [default]
    _v=$(grep "^$2=" "$1" 2>/dev/null | tail -n 1)
    _v=${_v#*=}
    [ -n "$_v" ] && echo "$_v" || echo "${3:-}"
}

kv_set() {
    # kv_set <file> <key> <value>
    mkdir -p "$(dirname "$1")"
    [ -f "$1" ] || : > "$1"
    grep -v "^$2=" "$1" > "$1.new" 2>/dev/null
    echo "$2=$3" >> "$1.new"
    mv "$1.new" "$1"
}

conf_get() { kv_get "$LUNE_CONF" "$1" "${2:-}"; }
conf_set() { kv_set "$LUNE_CONF" "$1" "$2"; }
cap_get()  { kv_get "$LUNE_CAPS" "$1" "${2:-}"; }
cap_set()  { kv_set "$LUNE_CAPS" "$1" "$2"; }

# ---------------------------------------------------------------------------
# sysfs access
# ---------------------------------------------------------------------------

node_read() {
    [ -r "$1" ] || return 1
    cat "$1" 2>/dev/null
}

node_write() {
    # node_write <path> <value>. Returns non-zero without writing if the node is
    # missing or rejects the value, so callers can fall back rather than assume.
    [ -w "$1" ] || return 1
    echo "$2" > "$1" 2>/dev/null || return 1
    return 0
}

is_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

clamp() {
    # clamp <value> <lo> <hi>
    [ "$1" -lt "$2" ] && { echo "$2"; return; }
    [ "$1" -gt "$3" ] && { echo "$3"; return; }
    echo "$1"
}

# ---------------------------------------------------------------------------
# Android settings
#
# settings(1) is the supported interface and survives reboots by itself, which
# is why the warm and dim paths prefer it over writing sysfs and then having to
# fight DisplayPowerController for the result.
# ---------------------------------------------------------------------------

setting_get() { settings get "$1" "$2" 2>/dev/null; }

setting_put() {
    settings put "$1" "$2" "$3" 2>/dev/null || return 1
    return 0
}

# Read back what the framework actually stored. The framework clamps values it
# considers out of range, so comparing the read-back against what we asked for
# is how the module tells "the overlay is active" from "the overlay installed
# but is not in effect" - a distinction most overlay tweaks never check.
setting_accepts() {
    # setting_accepts <namespace> <key> <value>
    _before=$(setting_get "$1" "$2")
    setting_put "$1" "$2" "$3" || return 1
    _after=$(setting_get "$1" "$2")
    [ -n "$_before" ] && [ "$_before" != "null" ] && setting_put "$1" "$2" "$_before"
    [ "$_after" = "$3" ]
}

# ---------------------------------------------------------------------------
# Dimming maths
# ---------------------------------------------------------------------------

# Extra Dim leaves (1 - 0.9556*q) of the signal at strength q. Given the
# fraction of light we want to keep, solve for the strength that gets us there.
keep_to_strength() {
    # keep_to_strength <keep_permille> -> strength percent 0..99
    _keep=$1
    [ "$_keep" -ge 1000 ] && { echo 0; return; }
    [ "$_keep" -lt 10 ] && _keep=10
    # keep is permille, strength is percent, so the numerator is 100 - not
    # 1000. Getting this wrong returns the ceiling for every input, which looks
    # plausible until you notice every level below the knee is equally dark.
    _q=$(( (1000 - _keep) * 100 / RBC_SLOPE_PERMILLE ))
    clamp "$_q" 0 99
}

strength_to_keep() {
    # strength_to_keep <strength percent> -> permille of signal retained
    echo $(( 1000 - ( $1 * RBC_SLOPE_PERMILLE / 100 ) ))
}

# Split a requested light level into a panel backlight percentage and an Extra
# Dim strength, keeping the backlight at or above the panel's PWM knee.
#
# This is the whole point of flicker-safe mode. A PWM-dimmed OLED flickers
# because the driver strobes the panel harder the lower the backlight goes. So
# do not take the brightness out of the backlight: hold the backlight above the
# knee where strobing is mild, and take the rest out of the signal with the
# colour matrix, which does not strobe at all.
split_for_flicker() {
    # split_for_flicker <target_pct 1..100> <knee_pct> -> "<backlight_pct> <strength_pct>"
    _target=$1
    _knee=$2
    if [ "$_target" -ge "$_knee" ]; then
        # Already above the knee - no trickery needed, and adding any would
        # only cost contrast for nothing.
        echo "$_target 0"
        return
    fi
    _keep=$(( _target * 1000 / _knee ))
    _strength=$(keep_to_strength "$_keep")
    echo "$_knee $_strength"
}

# ---------------------------------------------------------------------------
# Capability gates
# ---------------------------------------------------------------------------

have() { [ "$(cap_get "$1" no)" = "yes" ]; }

require_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || die "needs root (run through su)"
}

ensure_dirs() {
    mkdir -p "$LUNE_DIR" 2>/dev/null
    chmod 700 "$LUNE_DIR" 2>/dev/null
}
