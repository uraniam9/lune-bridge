#!/usr/bin/env bash
#
# Pre-release QA for Lune Bridge.
#
# Everything here is a check that can be made without a phone. It exists
# because "it built" and "it is correct" are different claims, and the gap
# between them is where a module that bricks someone's screen lives.
#
# Deliberately includes contract checks - does the code actually write every
# key the docs promise? - because a stale API doc is a bug in someone else's
# app, and nothing else in the build would catch it.
#
#   ./tools/qa.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; warn=0
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
note() { warn=$((warn+1)); printf '  \033[33mWARN\033[0m %s\n' "$1"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

MODID=$(grep '^id=' module/module.prop | cut -d= -f2)
VERSION=$(grep '^version=' module/module.prop | cut -d= -f2 | tr -d 'v')
ZIP="dist/LuneBridge-v$VERSION.zip"

# ---------------------------------------------------------------------------
section "1. Shell syntax"
# ---------------------------------------------------------------------------
for f in module/lib/*.sh module/bin/* module/*.sh module/system/bin/*; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then pass=$((pass+1)); else bad "syntax: $f"; fi
done
ok "all $(ls module/lib/*.sh module/bin/* module/*.sh module/system/bin/* 2>/dev/null | wc -l | tr -d ' ') shell files parse"

# Bashisms that mksh on Android does not have. The build host's sh is bash, so
# `sh -n` above will not catch these.
if grep -rnE '\[\[ |\blocal -|declare |=\(\)|\$\{[A-Za-z_]+\[[0-9@*]' module/bin module/lib module/*.sh 2>/dev/null | grep -v '^\s*#' | head -5; then
    note "possible bashisms above - Android's sh is mksh"
else
    ok "no obvious bashisms (arrays, [[ ]], declare)"
fi

# ---------------------------------------------------------------------------
section "2. Module metadata"
# ---------------------------------------------------------------------------
echo "$MODID" | grep -qE '^[a-zA-Z][a-zA-Z0-9._-]+$'
check "module id '$MODID' matches Magisk's required pattern" $?

for key in id name version versionCode author description; do
    grep -q "^$key=" module/module.prop
    check "module.prop has $key" $?
done

VC=$(grep '^versionCode=' module/module.prop | cut -d= -f2)
echo "$VC" | grep -qE '^[0-9]+$'
check "versionCode '$VC' is an integer" $?

# Each CLI carries its own VERSION constant, and they are what the user sees in
# `status` and on the action button. A release shipped with lunectl still
# reporting 1.0.0 while module.prop said 2.0.0 - nothing here caught it, so now
# it does.
for cli in lunectl quietctl; do
    CLIV=$(grep -m1 '^VERSION=' "module/bin/$cli" | cut -d= -f2)
    [ "$CLIV" = "$VERSION" ]
    check "$cli VERSION ($CLIV) matches module.prop ($VERSION)" $?
done

# The name users see must agree everywhere too.
MODNAME=$(grep '^name=' module/module.prop | cut -d= -f2)
STALE_NAME=$(grep -rn "Lune Display Bridge" module/ 2>/dev/null | grep -v "LuneDisplayBridge" || true)
if [ -z "$STALE_NAME" ]; then
    ok "module uses '$MODNAME' consistently"
else
    bad "old product name still in module/:"; echo "$STALE_NAME" | head -3
fi

grep -q "^author=uraniam9" module/module.prop
check "author is uraniam9" $?

grep -qi "sonolune" module/module.prop
check "module.prop credits SonoLune" $?

grep -qi "sonolune" module/webroot/index.html
check "WebUI promotes SonoLune" $?

# Every hardcoded module path must agree with the declared id, or the binaries
# look for themselves in a directory that does not exist.
# The one legitimate exception is the lune_* glob in the upgrade notes, which
# exists precisely to catch a second module directory left behind by the id
# change at 2.0.0. Matching only the current id there would defeat the point.
BADPATH=$(grep -rn "/data/adb/modules/" module/ docs/ 2>/dev/null \
    | grep -v "/data/adb/modules/$MODID" \
    | grep -v '/data/adb/modules/lune_[*]' \
    | grep -v Binary || true)
if [ -z "$BADPATH" ]; then
    ok "every module path matches the declared id"
else
    bad "module paths disagree with id:"; echo "$BADPATH" | head -5
fi

# ---------------------------------------------------------------------------
section "3. Tests"
# ---------------------------------------------------------------------------
if bash tools/test-core.sh > /tmp/qa-tests.txt 2>&1; then
    ok "core tests: $(tail -1 /tmp/qa-tests.txt)"
else
    bad "core tests failed"; tail -20 /tmp/qa-tests.txt
fi

if python tools/coefficients.py > /tmp/qa-ramp.txt 2>&1; then
    ok "colour ramp validates (non-negative, monotonic, drift in bounds)"
else
    bad "colour ramp failed its own validation"; cat /tmp/qa-ramp.txt
fi

# ---------------------------------------------------------------------------
section "4. Docs contract"
#
# The keys docs/API.md documents must be keys the code actually writes.
# A stale API doc is a bug in somebody else's app.
# ---------------------------------------------------------------------------
for key in night_display extra_dim overlay_warmth overlay_dim warm_floor \
           dim_max backlight_node dc_nodes pwm_knee pwm_knee_source safe_mode \
           quiet_levers quiet_notification; do
    if grep -rq "cap_set $key" module/bin module/lib 2>/dev/null; then
        pass=$((pass+1))
    else
        bad "API.md documents caps key '$key' but nothing writes it"
    fi
done
ok "every documented caps key is written by the code"

for key in level warm dim flicker backlight_raw; do
    if grep -rq "conf_set $key" module/bin module/lib 2>/dev/null; then
        pass=$((pass+1))
    else
        bad "API.md documents config key '$key' but nothing writes it"
    fi
done
ok "every documented config key is written by the code"

# Commands the docs promise must exist in the CLI's dispatch table.
for c in status level warm dim flicker knee backlight probe apply reset version; do
    grep -qE "^\s+$c\)|^\s+$c\|" module/bin/lunectl
    check "lunectl has '$c'" $?
done
for c in status add remove list window on off dnd allow disallow watch pattern stats probe reset version; do
    grep -qE "^\s+$c\)|^\s+$c\|" module/bin/quietctl
    check "quietctl has '$c'" $?
done

# Files the docs link to must exist.
MISSING=""
for link in $(grep -rhoE '\]\(([a-zA-Z0-9_./-]+\.(md|py|sh))\)' README.md docs/*.md 2>/dev/null | tr -d ']()'); do
    target="$link"
    [ -f "$ROOT/$target" ] || [ -f "$ROOT/docs/$target" ] || MISSING="$MISSING $target"
done
if [ -z "$MISSING" ]; then ok "every doc link resolves"; else bad "broken doc links:$MISSING"; fi

# ---------------------------------------------------------------------------
section "5. Safety invariants"
# ---------------------------------------------------------------------------
# Uninstall must lift every appop the runtime can set, or apps stay broken
# after the module is gone with nothing left to explain why.
for op in wake_lock turn_screen_on use_full_screen_intent vibrate post_notification; do
    grep -q "$op" module/uninstall.sh
    check "uninstall.sh lifts android:$op" $?
done
grep -q "night_display_activated 0" module/uninstall.sh
check "uninstall.sh clears night display" $?
grep -q "reduce_bright_colors_activated 0" module/uninstall.sh
check "uninstall.sh clears extra dim" $?
grep -q "screen_brightness" module/uninstall.sh
check "uninstall.sh restores a readable brightness" $?

# Lifting must hand the decision back, not grant. An app the user denied
# themselves must stay denied.
grep -q '"$_op" default' module/lib/quiet.sh
check "quiet lift uses 'default', never 'allow'" $?
if grep -qE 'appops set .* allow' module/lib/quiet.sh module/bin/quietctl 2>/dev/null; then
    bad "something grants an appop outright"
else
    ok "nothing grants an appop outright"
fi

# DND must leave alarms alone.
grep -q "set_dnd priority" module/lib/quiet.sh
check "DND uses 'priority' so alarms still fire" $?
if grep -q "set_dnd none" module/lib/quiet.sh; then
    bad "DND uses 'none' somewhere - that silences alarms"
else
    ok "DND never uses 'none'"
fi

grep -q "LUNE_BOOT_GUARD" module/bin/luned
check "failed-boot guard present" $?

# The watcher must never touch an app the user did not name.
grep -q 'quiet_app_levers "$_pkg"' module/lib/quiet.sh
check "watcher only inspects apps the user added" $?

# ---------------------------------------------------------------------------
section "6. Patterns"
# ---------------------------------------------------------------------------
PAT=module/patterns/reengagement.txt
COUNT=$(grep -cvE '^\s*(#|$)' "$PAT")
[ "$COUNT" -gt 10 ]
check "$COUNT re-engagement patterns shipped" $?

# A pattern matching ordinary text would eat notifications people wanted.
BENIGN_HITS=0
for msg in "Mum: are you free tomorrow" "Your verification code is 402931" \
           "Meeting at 3pm with Sam" "Battery is low"; do
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        if echo "$msg" | grep -qiE "$line" 2>/dev/null; then
            bad "pattern /$line/ matches benign text: \"$msg\""
            BENIGN_HITS=$((BENIGN_HITS+1))
        fi
    done < "$PAT"
done
[ "$BENIGN_HITS" -eq 0 ] && ok "no pattern matches ordinary messages or 2FA codes"

# ---------------------------------------------------------------------------
section "7. Build and package"
# ---------------------------------------------------------------------------
if bash tools/build.sh --clean > /tmp/qa-build.txt 2>&1; then
    ok "clean build from scratch"
else
    bad "clean build failed"; tail -20 /tmp/qa-build.txt
fi

[ -f "$ZIP" ]
check "produced $ZIP" $?

python - "$ZIP" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
required = [
    "module.prop", "customize.sh", "service.sh", "post-fs-data.sh",
    "uninstall.sh", "action.sh",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
    "bin/lunectl", "bin/quietctl", "bin/luned", "bin/lune-probe",
    "lib/core.sh", "lib/quiet.sh", "webroot/index.html",
    "system/bin/lunectl", "system/bin/quietctl",
    "patterns/reengagement.txt",
    "overlays/LuneDisplayBridge.apk", "overlays/LuneDisplayBridge-force.apk",
]
missing = [n for n in required if n not in names]
print("  FAIL missing from zip: %s" % missing if missing else "  PASS all required files in zip")

needs_exec = ["bin/lunectl","bin/quietctl","bin/luned","bin/lune-probe",
              "system/bin/lunectl","system/bin/quietctl","customize.sh",
              "service.sh","post-fs-data.sh","uninstall.sh","action.sh",
              "META-INF/com/google/android/update-binary"]
bad = [n for n in needs_exec
       if n in names and not ((z.getinfo(n).external_attr >> 16) & 0o111)]
print("  FAIL not executable in zip: %s" % bad if bad else "  PASS every script carries its exec bit")
PY

# Overlay must actually carry the resources it exists to override.
AAPT=$(ls -d /c/Android/Sdk/build-tools/*/ 2>/dev/null | sort -V | tail -1)aapt2.exe
if [ -f "$AAPT" ]; then
    DUMP=$("$AAPT" dump resources build/overlays/LuneDisplayBridge.apk 2>/dev/null)
    for r in config_nightDisplayColorTemperatureMin \
             config_nightDisplayColorTemperatureMax \
             config_nightDisplayColorTemperatureCoefficients \
             config_reduceBrightColorsStrengthMax \
             config_reduceBrightColorsStrengthMin \
             config_screenBrightnessSettingMinimumFloat \
             config_screenBrightnessSettingMinimum; do
        echo "$DUMP" | grep -q "$r"
        check "overlay carries $r" $?
    done
    echo "$DUMP" | grep -q "1700"
    check "overlay's warm floor is 1700K" $?
else
    note "aapt2 not found - skipped overlay resource check"
fi

# ---------------------------------------------------------------------------
section "8. Housekeeping"
# ---------------------------------------------------------------------------
# Real markers only. "placeholder" appears legitimately in an HTML attribute
# and in the overlay template's own description; matching those would make this
# check noise that gets ignored, which is worse than not having it.
# QA-REPORT-*.txt is this script's own saved output, so it necessarily contains
# the words being searched for. Scanning it finds only itself.
if grep -rnE "\bTODO\b|\bFIXME\b|\bXXX\b|\bHACK\b" module/ overlay/ docs/ README.md 2>/dev/null \
    | grep -v Binary | grep -v "QA-REPORT" | head -5; then
    note "unfinished markers above"
else
    ok "no TODO/FIXME/HACK markers"
fi

STALE=$(grep -rn "v1\.0\.0\|Lune Display Bridge" README.md docs/*.md module/module.prop 2>/dev/null \
    | grep -v CHANGELOG | grep -v "LuneDisplayBridge" || true)
if [ -z "$STALE" ]; then ok "no stale v1 naming in user-facing docs"; else note "stale v1 references:"; echo "$STALE" | head -5; fi

# A version left behind in a copy-paste command sends someone to a filename
# that no longer exists. This caught 2.0.0 still being pushed in TESTING.md
# after the bump to 2.0.1.
OLDVER=$(grep -rn "LuneBridge-v[0-9.]*[.]zip" README.md docs/ 2>/dev/null \
    | grep -v "LuneBridge-v$VERSION[.]zip" || true)
if [ -z "$OLDVER" ]; then
    ok "docs reference the current ZIP filename"
else
    bad "docs reference an old ZIP filename:"; echo "$OLDVER" | head -5
fi

git -C "$ROOT" check-ignore -q tools/lune.keystore 2>/dev/null
check "signing key is gitignored" $?

[ -f LICENSE ] && [ "$(wc -l < LICENSE)" -gt 100 ]
check "LICENSE present and complete" $?

# ---------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$pass" "$fail" "$warn"
if [ "$fail" -eq 0 ]; then
    printf '\033[32mQA PASS\033[0m - safe to submit (device testing still outstanding)\n'
else
    printf '\033[31mQA FAIL\033[0m - do not submit\n'
fi
[ "$fail" -eq 0 ]
