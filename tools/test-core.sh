#!/usr/bin/env bash
#
# Exercise the fixed-point maths in module/lib/core.sh on the build host.
#
# The device-facing parts of this module cannot be tested without a phone, but
# the arithmetic can, and the arithmetic is where an off-by-one turns into a
# screen that is twice as bright as asked for. Integer division truncates
# everywhere, so the tolerances below are real, not decorative.
#
#   ./tools/test-core.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# core.sh expects an Android environment. Give it a writable state dir and stub
# the two things it touches at load time.
export LUNE_MODDIR="$ROOT/module"
TMPSTATE="$(mktemp -d)"
trap 'rm -rf "$TMPSTATE"' EXIT

# quiet.sh sources core.sh, so this pulls in both.
# shellcheck source=../module/lib/quiet.sh
. "$ROOT/module/lib/quiet.sh"

# Both files hard-code /data/adb/lune, which does not exist on a build host.
# Repoint the state paths *after* sourcing, or the tests silently write nowhere.
LUNE_DIR="$TMPSTATE"
LUNE_CONF="$LUNE_DIR/config"
LUNE_CAPS="$LUNE_DIR/caps"
LUNE_LOG="$LUNE_DIR/log"
QUIET_CONF="$LUNE_DIR/quiet.conf"
QUIET_APPS="$LUNE_DIR/quiet.apps"
QUIET_STATS="$LUNE_DIR/quiet.stats"
QUIET_STATE="$LUNE_DIR/quiet.state"

pass=0; fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf '  FAIL %-42s got %-10s want %s\n' "$1" "$2" "$3"
    fi
}

near() {
    # near <label> <got> <want> <tolerance>
    local d=$(( $2 - $3 )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le "$4" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf '  FAIL %-42s got %-10s want %s (+/-%s)\n' "$1" "$2" "$3" "$4"
    fi
}

echo "clamp"
ok "below range"        "$(clamp 3 10 90)"    10
ok "above range"        "$(clamp 99 10 90)"   90
ok "inside range"       "$(clamp 50 10 90)"   50
ok "on lower bound"     "$(clamp 10 10 90)"   10

echo "is_int"
is_int 42    && ok "accepts digits"     yes yes || ok "accepts digits"     no yes
is_int ""    && ok "rejects empty"      no  yes || ok "rejects empty"      yes yes
is_int 1.5   && ok "rejects decimal"    no  yes || ok "rejects decimal"    yes yes
is_int -3    && ok "rejects negative"   no  yes || ok "rejects negative"   yes yes

echo "extra dim ramp"
# AOSP's ramp is (1 - 0.9556*strength). Anchor against values computed by hand
# from that formula, so a change to RBC_SLOPE_PERMILLE cannot pass silently.
ok  "strength 0 keeps everything"   "$(strength_to_keep 0)"   1000
near "strength 50 keeps ~52%"       "$(strength_to_keep 50)"  522 3
near "strength 90 keeps ~14%"       "$(strength_to_keep 90)"  140 3
near "strength 99 keeps ~5.4%"      "$(strength_to_keep 99)"   54 3

echo "ramp inversion"
# keep_to_strength must invert strength_to_keep, or the level split silently
# lands on the wrong brightness.
for s in 0 10 25 50 75 90 99; do
    k=$(strength_to_keep "$s")
    back=$(keep_to_strength "$k")
    near "round trip at strength $s" "$back" "$s" 1
done
ok "keep=1000 needs no dimming"  "$(keep_to_strength 1000)"  0
ok "clamped to the 99 ceiling"   "$(keep_to_strength 0)"     99

echo "flicker split"
# At or above the knee there is nothing to do, and adding colour-matrix
# dimming would cost contrast for no benefit.
ok "at the knee, no dimming"     "$(split_for_flicker 50 50)"   "50 0"
ok "above the knee, untouched"   "$(split_for_flicker 80 50)"   "80 0"

# Below the knee the backlight is pinned and the shortfall moves to the matrix.
set -- $(split_for_flicker 25 50)
ok   "half the knee pins backlight"  "$1" 50
near "half the knee needs ~52%"      "$2" 52 2

set -- $(split_for_flicker 5 50)
ok   "a tenth of the knee pins backlight" "$1" 50
near "a tenth of the knee needs ~94%"     "$2" 94 2

echo "flicker split round trip"
# The point of the split: perceived light should match what was asked for.
# perceived = backlight * keep(strength)
for target in 3 5 10 20 30 45; do
    set -- $(split_for_flicker "$target" 50)
    perceived=$(( $1 * $(strength_to_keep "$2") / 1000 ))
    near "target ${target}% is delivered" "$perceived" "$target" 1
done

echo "key=value store"
kv_set "$LUNE_DIR/t" alpha 1
kv_set "$LUNE_DIR/t" beta  2
kv_set "$LUNE_DIR/t" alpha 3
ok "overwrites rather than appends" "$(kv_get "$LUNE_DIR/t" alpha)" 3
ok "leaves other keys alone"        "$(kv_get "$LUNE_DIR/t" beta)"  2
ok "missing key returns default"    "$(kv_get "$LUNE_DIR/t" gamma fallback)" fallback
ok "no duplicate lines"             "$(grep -c '^alpha=' "$LUNE_DIR/t")" 1
kv_set "$LUNE_DIR/t" path "/sys/class/backlight/panel0-backlight"
ok "values with slashes survive"    "$(kv_get "$LUNE_DIR/t" path)" "/sys/class/backlight/panel0-backlight"

truthy() {
    # truthy <label> <command...> - passes when the command succeeds
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass+1))
    else fail=$((fail+1)); printf '  FAIL %-42s expected success\n' "$label"; fi
}

falsy() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        fail=$((fail+1)); printf '  FAIL %-42s expected failure\n' "$label"
    else pass=$((pass+1)); fi
}

echo "flicker floor per knee"
# The WebUI and the app both show this number before the user commits to a
# knee, so all three implementations have to agree. They each compute
# knee * 54 / 1000 in integers; rounding instead of truncating in the UI once
# promised 5% where the CLI delivered 4%.
for pair in "60 3" "70 3" "80 4" "85 4" "90 4"; do
    set -- $pair
    set -- "$1" "$2" $(split_for_flicker 1 "$1")
    floor=$(( $3 * $(strength_to_keep "$4") / 1000 ))
    ok "knee $1 floors at $2%" "$floor" "$2"
done

echo "flicker split at a high knee"
# A panel measured at 85% leaves very little room: the backlight is pinned high,
# so everything has to come from Extra Dim, which tops out at 99%. The darkest
# reachable level is therefore knee * 0.054, not 1%. Real numbers from a Nothing
# A065, and the reason lunectl reports the floor instead of silently missing it.
set -- $(split_for_flicker 3 85)
ok   "level 3 pins backlight at the knee"  "$1" 85
ok   "level 3 saturates Extra Dim"         "$2" 99
delivered=$(( $1 * $(strength_to_keep "$2") / 1000 ))
near "level 3 actually delivers ~4%"       "$delivered" 4 1
# Above the floor it should be accurate again.
for target in 5 8 10 20 40; do
    set -- $(split_for_flicker "$target" 85)
    delivered=$(( $1 * $(strength_to_keep "$2") / 1000 ))
    near "level ${target}% delivered at knee 85" "$delivered" "$target" 1
done
set -- $(split_for_flicker 90 85)
ok "above the knee the backlight is used directly" "$1 $2" "90 0"

echo "quiet: time parsing"
ok "midnight"            "$(quiet_hhmm_to_min 0000)" 0
# 08 and 09 are the classic trap: $(( 08 )) is an octal error in POSIX shells,
# so a naive parser breaks for exactly one hour of the morning.
ok "0800 is not octal"   "$(quiet_hhmm_to_min 0800)" 480
ok "0900 is not octal"   "$(quiet_hhmm_to_min 0900)" 540
ok "half past nine"      "$(quiet_hhmm_to_min 0930)" 570
ok "9pm"                 "$(quiet_hhmm_to_min 2100)" 1260
ok "last minute of day"  "$(quiet_hhmm_to_min 2359)" 1439
falsy "rejects hour 24"   quiet_hhmm_to_min 2400
falsy "rejects minute 60" quiet_hhmm_to_min 0060
falsy "rejects 3 digits"  quiet_hhmm_to_min 930
falsy "rejects letters"   quiet_hhmm_to_min abcd
falsy "rejects empty"     quiet_hhmm_to_min ""

echo "quiet: window validation"
truthy "accepts overnight"      quiet_window_valid 2100-0800
truthy "accepts daytime"        quiet_window_valid 0900-1700
falsy  "rejects equal ends"     quiet_window_valid 2100-2100
falsy  "rejects colons"         quiet_window_valid 21:00-08:00
falsy  "rejects bad hour"       quiet_window_valid 2500-0800
falsy  "rejects missing half"   quiet_window_valid 2100

echo "quiet: daytime window 0900-1700"
falsy  "before start (08:59)"   quiet_in_window 0900-1700 539
truthy "at start (09:00)"       quiet_in_window 0900-1700 540
truthy "midday"                 quiet_in_window 0900-1700 720
falsy  "at end (17:00)"         quiet_in_window 0900-1700 1020
falsy  "after end"              quiet_in_window 0900-1700 1200
falsy  "middle of the night"    quiet_in_window 0900-1700 120

echo "quiet: overnight window 2100-0800"
# The case that matters. A window crossing midnight must not mean "never",
# which is what a naive start<=now<end comparison gives you.
falsy  "before start (20:59)"   quiet_in_window 2100-0800 1259
truthy "at start (21:00)"       quiet_in_window 2100-0800 1260
truthy "late evening (23:30)"   quiet_in_window 2100-0800 1410
truthy "across midnight (00:00)" quiet_in_window 2100-0800 0
truthy "small hours (03:00)"    quiet_in_window 2100-0800 180
truthy "just before end (07:59)" quiet_in_window 2100-0800 479
falsy  "at end (08:00)"         quiet_in_window 2100-0800 480
falsy  "midday"                 quiet_in_window 2100-0800 720

echo "quiet: lever mapping"
ok "wake"        "$(quiet_op_for wake)"       "android:wake_lock"
ok "screen"      "$(quiet_op_for screen)"     "android:turn_screen_on"
ok "fullscreen"  "$(quiet_op_for fullscreen)" "android:use_full_screen_intent"
ok "vibrate"     "$(quiet_op_for vibrate)"    "android:vibrate"
ok "notify"      "$(quiet_op_for notify)"     "android:post_notification"
ok "unknown is empty" "$(quiet_op_for nonsense)" ""

echo "quiet: notification keys"
ok "extracts package" "$(quiet_key_pkg '0|com.example.app|1|null|10234')" "com.example.app"
ok "handles null tag" "$(quiet_key_pkg '0|com.a.b|42|tag|1000')" "com.a.b"

echo "quiet: app rules"
quiet_app_set com.example.one "wake,screen"
quiet_app_set com.example.two "vibrate"
quiet_app_set com.example.one "wake,fullscreen"
ok "overwrites, not appends" "$(quiet_app_levers com.example.one)" "wake,fullscreen"
ok "leaves others alone"     "$(quiet_app_levers com.example.two)" "vibrate"
ok "no duplicate entries"    "$(grep -c '^com.example.one:' "$QUIET_APPS")" 1
ok "lists both"              "$(quiet_app_list | wc -l | tr -d ' ')" 2
quiet_app_remove com.example.one
ok "removes cleanly"         "$(quiet_app_levers com.example.one)" ""
ok "removal keeps the rest"  "$(quiet_app_levers com.example.two)" "vibrate"

echo "quiet: scheduler cadence"
# A user who only wanted the display half should not be paying for a scheduler
# that has nothing to schedule.
rm -f "$QUIET_APPS" "$QUIET_CONF" "$QUIET_STATE"
ok "idle when unconfigured"  "$(quiet_interval)" 3600
quiet_app_set com.example.one "wake"
ok "slow with rules only"    "$(quiet_interval)" 300
qconf_set window 2100-0800
ok "minute during schedule"  "$(quiet_interval)" 60

echo "update: reading the release feed"
# No JSON parser here, so the field reader is hand-rolled and worth pinning.
# The URL matters most: it contains colons, and a naive split on the first one
# would hand back "//github.com/..." and send people nowhere.
FEED='{
  "version": "v2.0.3",
  "versionCode": 20003,
  "zipUrl": "https://github.com/uraniam9/lune-bridge/releases/download/v2.0.3/LuneBridge-v2.0.3.zip",
  "releaseUrl": "https://github.com/uraniam9/lune-bridge/releases/tag/v2.0.3",
  "changelog": "https://github.com/uraniam9/lune-bridge/raw/main/CHANGELOG.md"
}'
ok "version"        "$(json_field "$FEED" version)"     "v2.0.3"
ok "versionCode"    "$(json_field "$FEED" versionCode)" "20003"
ok "url keeps colons" "$(json_field "$FEED" releaseUrl)"    "https://github.com/uraniam9/lune-bridge/releases/tag/v2.0.3"
ok "absent key empty" "$(json_field "$FEED" nosuchkey)"  ""
# Anything that is not the feed must not be read as a version, or a captive
# portal login page turns into "you are out of date".
ok "garbage is not a code" "$(json_field '<html>404</html>' versionCode)" ""

echo "probe: settings are put back the way they were found"
# This is the one that bricked lock screens. The probe writes a test value to
# see whether the framework still clamps it, and has to undo that. When the key
# had never been written it used to leave the test value in place, so a device
# with Extra Dim already on came back from a reboot at 95 strength: a lock
# screen too dark to read, on a phone that was working a minute earlier.
SETDB="$TMPSTATE/settings"
: > "$SETDB"
settings() {
    case "$1" in
        get)    grep "^$2/$3=" "$SETDB" 2>/dev/null | tail -1 | cut -d= -f2- ;;
        put)    printf '%s/%s=%s
' "$2" "$3" "$4" >> "$SETDB" ;;
        delete) grep -v "^$2/$3=" "$SETDB" > "$SETDB.n" 2>/dev/null; mv "$SETDB.n" "$SETDB" ;;
    esac
}

# A key that already holds a value must come back holding that same value.
settings put secure reduce_bright_colors_level 50
setting_accepts secure reduce_bright_colors_level 95
ok "existing value restored"   "$(setting_get secure reduce_bright_colors_level)" 50

# A key that was never set must be left unset, not holding the probe's value.
settings delete secure reduce_bright_colors_level
setting_accepts secure reduce_bright_colors_level 95
ok "unset key left unset"      "$(setting_get secure reduce_bright_colors_level)" ""

# Same for the warm floor, which is the other value the boot probe writes.
settings delete secure night_display_color_temperature
setting_accepts secure night_display_color_temperature 1700
ok "warm floor left unset"     "$(setting_get secure night_display_color_temperature)" ""

# And the answer it returns has to stay correct through all of that.
settings() {
    case "$1" in
        get)    grep "^$2/$3=" "$SETDB" 2>/dev/null | tail -1 | cut -d= -f2- ;;
        put)    printf '%s/%s=%s
' "$2" "$3" "90" >> "$SETDB" ;;   # framework clamps
        delete) grep -v "^$2/$3=" "$SETDB" > "$SETDB.n" 2>/dev/null; mv "$SETDB.n" "$SETDB" ;;
    esac
}
settings delete secure reduce_bright_colors_level
setting_accepts secure reduce_bright_colors_level 95
ok "clamped value reports no"  "$?" 1
unset -f settings

echo "quiet: dnd preference while running"
# Changing the preference mid-quiet has to act in both directions. Stub the two
# calls that reach the framework so the bookkeeping is what gets tested.
rm -f "$QUIET_APPS" "$QUIET_CONF" "$QUIET_STATE"
DND_CALLS=""
quiet_dnd_on()  { DND_CALLS="$DND_CALLS on"; }
quiet_dnd_off() { DND_CALLS="$DND_CALLS off"; }

# Quiet mode off: the preference is recorded and nothing is touched.
kv_set "$QUIET_STATE" mode off
quiet_dnd_prefer on
ok "pref stored"               "$(qconf_get dnd off)" on
ok "nothing applied when idle" "$DND_CALLS" ""

# Quiet mode already running, preference switched on: apply now.
kv_set "$QUIET_STATE" mode on
quiet_dnd_prefer off          # clear first so the next call has work to do
DND_CALLS=""
quiet_dnd_prefer on
ok "applied while running"     "$DND_CALLS" " on"
ok "marked as ours"            "$(kv_get "$QUIET_STATE" dnd_applied no)" yes

# Switched off again: release now.
DND_CALLS=""
quiet_dnd_prefer off
ok "released while running"    "$DND_CALLS" " off"
ok "no longer ours"            "$(kv_get "$QUIET_STATE" dnd_applied no)" no

# Switching on twice must not double-apply.
DND_CALLS=""
quiet_dnd_prefer on
quiet_dnd_prefer on
ok "applied once only"         "$DND_CALLS" " on"

echo "quiet: manual override"
# Tapping the manual toggle inside quiet hours used to last about twenty
# seconds, because the next tick re-applied whatever the window said. The
# override has to outlive the tick, and has to stop mattering at the next
# window edge.
rm -f "$QUIET_APPS" "$QUIET_CONF" "$QUIET_STATE"
ok "no override without a schedule" "$(quiet_override_set off; kv_get "$QUIET_STATE" override none)" none

qconf_set window 2100-0800
# Pretend it is 22:00, inside the window, and the user has switched quiet off.
quiet_now_minutes() { echo 1320; }
quiet_override_set off
ok "override recorded"          "$(kv_get "$QUIET_STATE" override "")" off
ok "schedule answer recorded"   "$(kv_get "$QUIET_STATE" override_sched "")" on

# Still 22:00: the tick must leave the override alone.
kv_set "$QUIET_STATE" mode off
quiet_tick
ok "override survives the tick" "$(quiet_mode)" off
ok "override still set"         "$(kv_get "$QUIET_STATE" override "")" off

# 12:00, outside the window: the edge has been crossed, so it expires.
quiet_now_minutes() { echo 720; }
quiet_tick
ok "override cleared at the edge" "$(kv_get "$QUIET_STATE" override "")" ""

# And a new schedule outranks an older override.
quiet_now_minutes() { echo 1320; }
quiet_override_set on
qconf_set window 2100-0800
quiet_override_clear
ok "new schedule clears it"     "$(kv_get "$QUIET_STATE" override "")" ""

echo "quiet: shipped patterns"
PAT="$ROOT/module/patterns/reengagement.txt"
ok "pattern file exists" "$([ -f "$PAT" ] && echo yes)" yes
# Every shipped pattern must be a valid ERE, or the watcher throws on each poll.
bad=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    echo "test string" | grep -qiE "$line" 2>/dev/null || true
    if ! echo "" | grep -qE "$line" 2>/dev/null; then
        # grep returns 1 for "no match" and 2 for a bad pattern.
        [ $? -gt 1 ] && { bad=$((bad+1)); printf '  FAIL bad regex: %s\n' "$line"; }
    fi
done < "$PAT"
ok "all patterns compile" "$bad" 0
# A pattern that matches everyday text would eat notifications people wanted.
benign="Mum: are you free tomorrow"
matched=""
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    echo "$benign" | grep -qiE "$line" 2>/dev/null && matched="$line"
done < "$PAT"
ok "no pattern matches a normal message" "$matched" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
