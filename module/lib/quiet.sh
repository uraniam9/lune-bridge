#!/system/bin/sh
#
# Lune Bridge - Quiet Field engine.
#
# Attention control built the same way the display suite is: by driving
# Android's own mechanisms rather than inventing one. Nothing here hooks a
# process, patches a framework method, or needs Xposed/LSPosed. It is all
# appops and `cmd notification`, which means it survives ROM updates and works
# the same on a Pixel and on a heavily skinned OEM build.
#
# Three tiers, in order of how cheap and reliable they are:
#
#   1. appops       - a permission the app simply no longer has. Free, instant,
#                     enforced by the framework, persists across reboots.
#   2. DND windows  - the system's own Do Not Disturb, with a per-app bypass
#                     list, switched on a schedule.
#   3. the watcher  - polls the active notification list and snoozes anything
#                     matching a re-engagement pattern. Opt-in, because polling
#                     costs battery and the notification is briefly visible
#                     before it goes. Honest about both.
#
# Sourced by quietctl and luned.

# shellcheck source=core.sh
. "${LUNE_MODDIR:-/data/adb/modules/lune_bridge}/lib/core.sh"

QUIET_CONF=$LUNE_DIR/quiet.conf
QUIET_APPS=$LUNE_DIR/quiet.apps
QUIET_ALLOW=$LUNE_DIR/quiet.allow
QUIET_PATTERNS=$LUNE_DIR/quiet.patterns
QUIET_STATS=$LUNE_DIR/quiet.stats
QUIET_STATE=$LUNE_DIR/quiet.state

# Levers, mapped to the appop that actually implements each one. The names come
# from AppOpsManager's OPSTR_ constants, not from guesswork.
#
#   wake       app may not hold a wake lock, so it cannot keep the CPU or
#              screen up in the background
#   screen     app may not turn the screen on (Android 14+)
#   fullscreen app may not take the whole screen over with a notification
#              (Android 14+) - this is the one that stops "call-style" ads
#   vibrate    app may not buzz
#   notify     app may not post notifications at all. Blunt; opt-in per app.
#
# Availability differs by Android version, so quiet_probe_ops tests each one
# against this device instead of assuming from the SDK number.
OP_wake="android:wake_lock"
OP_screen="android:turn_screen_on"
OP_fullscreen="android:use_full_screen_intent"
OP_vibrate="android:vibrate"
OP_notify="android:post_notification"

ALL_LEVERS="wake screen fullscreen vibrate notify"

quiet_op_for() {
    case "$1" in
        wake)       echo "$OP_wake" ;;
        screen)     echo "$OP_screen" ;;
        fullscreen) echo "$OP_fullscreen" ;;
        vibrate)    echo "$OP_vibrate" ;;
        notify)     echo "$OP_notify" ;;
        *)          echo "" ;;
    esac
}

qconf_get() { kv_get "$QUIET_CONF" "$1" "${2:-}"; }
qconf_set() { kv_set "$QUIET_CONF" "$1" "$2"; }

# ---------------------------------------------------------------------------
# Capability probing
# ---------------------------------------------------------------------------

# Whether this device knows an op at all. `cmd appops get` on an unknown op
# fails rather than returning nothing, which is what we key off - it means we
# never have to hardcode "this arrived in API 34" and be wrong on a backport.
quiet_op_supported() {
    _out=$(cmd appops get android "$1" 2>&1)
    case "$_out" in
        *"Unknown operation"*|*"Error"*|*"error"*|*Exception*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

quiet_probe_ops() {
    _ok=""
    for _lever in $ALL_LEVERS; do
        if quiet_op_supported "$(quiet_op_for "$_lever")"; then
            _ok="$_ok$_lever "
        fi
    done
    cap_set quiet_levers "${_ok% }"
    [ -n "$_ok" ] && cap_set quiet yes || cap_set quiet no

    # `cmd notification` has been present since Android 8, but set_dnd needs
    # policy access that some OEM builds restrict, so test rather than assume.
    if cmd notification list >/dev/null 2>&1; then
        cap_set quiet_notification yes
    else
        cap_set quiet_notification no
    fi
}

quiet_lever_supported() {
    case " $(cap_get quiet_levers) " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Per-app rules
#
# Stored as "package:lever,lever" lines. Plain text on purpose - someone
# debugging this at 2am should be able to read and edit it with `vi`.
# ---------------------------------------------------------------------------

quiet_app_levers() {
    grep "^$1:" "$QUIET_APPS" 2>/dev/null | tail -n 1 | cut -d: -f2
}

quiet_app_list() {
    [ -f "$QUIET_APPS" ] || return 0
    cut -d: -f1 "$QUIET_APPS" 2>/dev/null
}

quiet_app_set() {
    # quiet_app_set <pkg> <comma-separated levers>
    mkdir -p "$LUNE_DIR"
    [ -f "$QUIET_APPS" ] || : > "$QUIET_APPS"
    grep -v "^$1:" "$QUIET_APPS" > "$QUIET_APPS.new" 2>/dev/null
    echo "$1:$2" >> "$QUIET_APPS.new"
    mv "$QUIET_APPS.new" "$QUIET_APPS"
}

quiet_app_remove() {
    [ -f "$QUIET_APPS" ] || return 0
    grep -v "^$1:" "$QUIET_APPS" > "$QUIET_APPS.new" 2>/dev/null
    mv "$QUIET_APPS.new" "$QUIET_APPS"
}

quiet_pkg_installed() {
    pm path "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Applying and lifting
#
# "ignore" rather than "deny": ignore makes the framework silently pretend the
# call succeeded, which apps handle gracefully. deny throws a SecurityException
# and takes badly written apps down with it. Quieting an app should not crash
# it - a crashing app is noisier than the notification was.
# ---------------------------------------------------------------------------

quiet_apply_pkg() {
    # quiet_apply_pkg <pkg> <levers csv>
    _pkg=$1
    _levers=$(echo "$2" | tr ',' ' ')
    for _lever in $_levers; do
        _op=$(quiet_op_for "$_lever")
        [ -n "$_op" ] || continue
        quiet_lever_supported "$_lever" || continue
        cmd appops set "$_pkg" "$_op" ignore >/dev/null 2>&1
    done
}

quiet_lift_pkg() {
    _pkg=$1
    _levers=$(echo "$2" | tr ',' ' ')
    for _lever in $_levers; do
        _op=$(quiet_op_for "$_lever")
        [ -n "$_op" ] || continue
        quiet_lever_supported "$_lever" || continue
        # "default" hands the decision back to the framework, which is not the
        # same as "allow" - an app the user themselves denied stays denied.
        cmd appops set "$_pkg" "$_op" default >/dev/null 2>&1
    done
}

quiet_apply_all() {
    [ -f "$QUIET_APPS" ] || return 0
    while IFS=: read -r _pkg _levers; do
        [ -n "$_pkg" ] || continue
        quiet_apply_pkg "$_pkg" "$_levers"
    done < "$QUIET_APPS"
}

quiet_lift_all() {
    [ -f "$QUIET_APPS" ] || return 0
    while IFS=: read -r _pkg _levers; do
        [ -n "$_pkg" ] || continue
        quiet_lift_pkg "$_pkg" "$_levers"
    done < "$QUIET_APPS"
}

# ---------------------------------------------------------------------------
# Quiet windows
#
# Stored as HHMM-HHMM. All arithmetic in minutes past midnight, integer only.
# ---------------------------------------------------------------------------

quiet_hhmm_to_min() {
    # "2130" -> 1290. Returns non-zero on anything malformed rather than
    # quietly producing a number, because a mis-parsed window silently means
    # the wrong hours of someone's night.
    _v=$1
    case "$_v" in
        [0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    _h=${_v%??}
    _m=${_v#??}
    # Strip leading zeros; "08" would otherwise be read as octal by $(( )).
    _h=$(( 1${_h} - 100 ))
    _m=$(( 1${_m} - 100 ))
    [ "$_h" -le 23 ] || return 1
    [ "$_m" -le 59 ] || return 1
    echo $(( _h * 60 + _m ))
}

quiet_window_valid() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    _s=$(quiet_hhmm_to_min "${1%-*}") || return 1
    _e=$(quiet_hhmm_to_min "${1#*-}") || return 1
    [ "$_s" != "$_e" ] || return 1
    return 0
}

# Is <now_minutes> inside <window>? Handles the overnight case, which is the
# normal case here: 2100-0800 has to mean "tonight through tomorrow morning",
# not "never".
quiet_in_window() {
    # quiet_in_window <window HHMM-HHMM> <now minutes>
    _start=$(quiet_hhmm_to_min "${1%-*}") || return 1
    _end=$(quiet_hhmm_to_min "${1#*-}") || return 1
    _now=$2
    if [ "$_start" -lt "$_end" ]; then
        [ "$_now" -ge "$_start" ] && [ "$_now" -lt "$_end" ]
    else
        [ "$_now" -ge "$_start" ] || [ "$_now" -lt "$_end" ]
    fi
}

quiet_now_minutes() {
    _h=$(date +%H)
    _m=$(date +%M)
    echo $(( (1$_h - 100) * 60 + (1$_m - 100) ))
}

# ---------------------------------------------------------------------------
# Do Not Disturb
# ---------------------------------------------------------------------------

# "priority" rather than "none": it keeps alarms working. A quiet-hours feature
# that eats someone's alarm has done more harm than the notifications it
# silenced, and this is the failure people never forgive.
quiet_dnd_on()  { cmd notification set_dnd priority >/dev/null 2>&1; }
quiet_dnd_off() { cmd notification set_dnd off >/dev/null 2>&1; }

quiet_allow_list() { cat "$QUIET_ALLOW" 2>/dev/null; }

quiet_allow_add() {
    mkdir -p "$LUNE_DIR"
    touch "$QUIET_ALLOW"
    grep -qx "$1" "$QUIET_ALLOW" 2>/dev/null || echo "$1" >> "$QUIET_ALLOW"
    cmd notification allow_dnd "$1" >/dev/null 2>&1
}

quiet_allow_remove() {
    [ -f "$QUIET_ALLOW" ] || return 0
    grep -vx "$1" "$QUIET_ALLOW" > "$QUIET_ALLOW.new" 2>/dev/null
    mv "$QUIET_ALLOW.new" "$QUIET_ALLOW"
    cmd notification disallow_dnd "$1" >/dev/null 2>&1
}

quiet_allow_sync() {
    [ -f "$QUIET_ALLOW" ] || return 0
    while read -r _pkg; do
        [ -n "$_pkg" ] && cmd notification allow_dnd "$_pkg" >/dev/null 2>&1
    done < "$QUIET_ALLOW"
}

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

quiet_stat_bump() {
    _today=$(date +%Y-%m-%d)
    _key="$_today.$1"
    _n=$(kv_get "$QUIET_STATS" "$_key" 0)
    is_int "$_n" || _n=0
    kv_set "$QUIET_STATS" "$_key" $(( _n + 1 ))
}

quiet_stat_today() {
    kv_get "$QUIET_STATS" "$(date +%Y-%m-%d).$1" 0
}

# Keep only the last 14 days, so the file cannot grow without bound on a device
# nobody ever resets.
quiet_stats_trim() {
    [ -f "$QUIET_STATS" ] || return 0
    _cutoff=$(date -d '14 days ago' +%Y-%m-%d 2>/dev/null) || return 0
    awk -F. -v c="$_cutoff" '$1 >= c' "$QUIET_STATS" > "$QUIET_STATS.new" 2>/dev/null \
        && mv "$QUIET_STATS.new" "$QUIET_STATS"
}

# ---------------------------------------------------------------------------
# The watcher
#
# The only part of Quiet Field that is not free. `cmd notification list` gives
# keys, `get` dumps the record, `snooze` removes it. Polling means the
# notification is briefly visible before it goes - there is no way around that
# without hooking the framework, and hooking is what this module exists to
# avoid. Off by default, and the UI says what it costs.
# ---------------------------------------------------------------------------

quiet_watch_patterns() {
    cat "$QUIET_PATTERNS" 2>/dev/null
}

# A notification key looks like "0|com.example.app|1|null|10234".
quiet_key_pkg() {
    echo "$1" | cut -d'|' -f2
}

quiet_watch_once() {
    [ "$(qconf_get watch off)" = "on" ] || return 0
    [ -s "$QUIET_PATTERNS" ] || return 0

    _keys=$(cmd notification list 2>/dev/null) || return 0
    [ -n "$_keys" ] || return 0

    _snooze_ms=$(qconf_get watch_snooze_ms 3600000)

    echo "$_keys" | while read -r _key; do
        [ -n "$_key" ] || continue
        _pkg=$(quiet_key_pkg "$_key")

        # Only ever touch apps the user named. A watcher with global reach is
        # a watcher that eventually eats a two-factor code.
        [ -n "$(quiet_app_levers "$_pkg")" ] || continue

        _dump=$(cmd notification get "$_key" 2>/dev/null) || continue
        [ -n "$_dump" ] || continue

        quiet_watch_patterns | while read -r _pattern; do
            [ -n "$_pattern" ] || continue
            case "$_pattern" in \#*) continue ;; esac
            if echo "$_dump" | grep -qiE "$_pattern"; then
                cmd notification snooze --for "$_snooze_ms" "$_key" >/dev/null 2>&1
                quiet_stat_bump stripped
                log "quiet: snoozed $_pkg (matched: $_pattern)"
                break
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Mode
# ---------------------------------------------------------------------------

quiet_mode() { kv_get "$QUIET_STATE" mode off; }

quiet_enter() {
    [ "$(quiet_mode)" = "on" ] && return 0
    quiet_apply_all
    quiet_allow_sync
    [ "$(qconf_get dnd on)" = "on" ] && quiet_dnd_on
    kv_set "$QUIET_STATE" mode on
    kv_set "$QUIET_STATE" since "$(date '+%Y-%m-%d %H:%M:%S')"
    quiet_stat_bump entered
    log "quiet: entered"
}

quiet_leave() {
    [ "$(quiet_mode)" = "off" ] && return 0
    quiet_lift_all
    [ "$(qconf_get dnd on)" = "on" ] && quiet_dnd_off
    kv_set "$QUIET_STATE" mode off
    log "quiet: left"
}

# How often luned should call quiet_tick, in seconds.
#
# Returns something large when Quiet Field is not in use, so a user who only
# ever wanted the display features is not paying for a scheduler that has
# nothing to schedule. This is the difference between a module that costs
# nothing when idle and one that shows up in battery stats.
quiet_interval() {
    if [ "$(qconf_get watch off)" = "on" ] && [ "$(quiet_mode)" = "on" ]; then
        qconf_get watch_interval 20
        return
    fi
    if [ -n "$(qconf_get window)" ]; then
        echo 60          # minute resolution is enough for quiet hours
        return
    fi
    if [ -s "$QUIET_APPS" ] || [ "$(quiet_mode)" = "on" ]; then
        echo 300
        return
    fi
    echo 3600            # nothing configured - effectively asleep
}

# Called by luned on the cadence above. Cheap by design: when no window is set
# and nothing is scheduled, this does nothing at all.
quiet_tick() {
    _window=$(qconf_get window)
    if [ -z "$_window" ]; then
        # No schedule. Manual mode: whatever the user set stays set.
        [ "$(quiet_mode)" = "on" ] && quiet_watch_once
        return 0
    fi
    if quiet_in_window "$_window" "$(quiet_now_minutes)"; then
        quiet_enter
        quiet_watch_once
    else
        quiet_leave
    fi
}
