#!/usr/bin/env bash
#
# Build Lune Bridge: compile the Runtime Resource Overlay, sign it, and
# assemble the flashable module zip.
#
# Runs on Linux, macOS and Windows (Git Bash). Needs an Android SDK with
# build-tools and one platform, plus a JDK for keytool/apksigner. Everything
# else - the colour maths, the zipping - is done with Python so the build does
# not depend on tools that may not be installed.
#
#   ./tools/build.sh              build everything
#   ./tools/build.sh --clean      remove build output first

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
PKG=com.soundsoftlab.lune.overlay

VERSION="$(grep '^version=' "$ROOT/module/module.prop" | cut -d= -f2 | tr -d 'v')"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m !! \033[0m %s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "--clean" ] && { rm -rf "$BUILD" "$DIST"; say "cleaned"; }

# ---------------------------------------------------------------------------
# Locate the toolchain
# ---------------------------------------------------------------------------

EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; esac

find_sdk() {
    for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
                     "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" \
                     /c/Android/Sdk /usr/lib/android-sdk; do
        [ -n "$candidate" ] && [ -d "$candidate/build-tools" ] && { echo "$candidate"; return; }
    done
    return 1
}

SDK="$(find_sdk)" || die "no Android SDK found - set ANDROID_HOME"
BT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -1)"
BT="${BT%/}"
PLATFORM="$(ls -d "$SDK"/platforms/android-*/ | sort -V | tail -1)"
PLATFORM="${PLATFORM%/}"
ANDROID_JAR="$PLATFORM/android.jar"

AAPT2="$BT/aapt2$EXE"
ZIPALIGN="$BT/zipalign$EXE"
APKSIGNER="$BT/apksigner"
[ -f "$APKSIGNER.bat" ] && APKSIGNER="$APKSIGNER.bat"

[ -f "$AAPT2" ]        || die "aapt2 not found in $BT"
[ -f "$ANDROID_JAR" ]  || die "android.jar not found in $PLATFORM"

PYTHON="$(command -v python3 || command -v python)" || die "python is required"

# apksigner and keytool are JVM tools. Android Studio ships a JDK that most
# people never put on PATH, so find it rather than making them do it.
find_java_home() {
    [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool$EXE" ] && { echo "$JAVA_HOME"; return; }
    local jre
    jre="$(command -v java || true)"
    [ -n "$jre" ] && { dirname "$(dirname "$jre")"; return; }
    for guess in "/c/Program Files/Android/Android Studio/jbr" \
                 "/c/Program Files/Java"/jdk* \
                 "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                 "$HOME/.jdks"/*; do
        [ -x "$guess/bin/keytool$EXE" ] && { echo "$guess"; return; }
    done
    return 1
}

JAVA_HOME="$(find_java_home)" || die "no JDK found - install one or set JAVA_HOME"
# The Windows .bat wrappers need a native path, not an MSYS one.
command -v cygpath >/dev/null 2>&1 && JAVA_HOME="$(cygpath -w "$JAVA_HOME")"
export JAVA_HOME
KEYTOOL="$(cygpath -u "$JAVA_HOME" 2>/dev/null || echo "$JAVA_HOME")/bin/keytool$EXE"

say "sdk        $SDK"
say "build-tools $(basename "$BT")   platform $(basename "$PLATFORM")"
say "version    $VERSION"

# ---------------------------------------------------------------------------
# Colour ramp
#
# Generated rather than hard-coded, and the generator refuses to emit a ramp
# that fails its own validation, so a bad curve cannot silently reach a build.
# ---------------------------------------------------------------------------

mkdir -p "$BUILD"

say "running core tests"
if ! bash "$ROOT/tools/test-core.sh" > "$BUILD/test-report.txt" 2>&1; then
    cat "$BUILD/test-report.txt"
    die "core tests failed - refusing to build"
fi
tail -1 "$BUILD/test-report.txt" | sed 's/^/    /'

say "computing night ramp"
if ! "$PYTHON" "$ROOT/tools/coefficients.py" > "$BUILD/ramp-report.txt" 2>&1; then
    cat "$BUILD/ramp-report.txt"
    die "coefficients.py failed its own validation - refusing to build"
fi
grep -E 'drift|monotonic|non-negative|PASS|FAIL' "$BUILD/ramp-report.txt" | sed 's/^/    /'

COEFFS="$("$PYTHON" "$ROOT/tools/coefficients.py" --xml)"

# ---------------------------------------------------------------------------
# Build one overlay variant
# ---------------------------------------------------------------------------

FORCE_BLOCK='    <!-- Opt-in: some OEM ROMs disable these outright. Only meaningful
         where the HWC really does accelerate the colour transform, which is
         why this is a separate variant rather than the default. -->
    <bool name="config_nightDisplayAvailable">true</bool>
    <bool name="config_reduceBrightColorsAvailable">true</bool>'

build_overlay() {
    local variant="$1" force="$2" out="$3"
    local dir="$BUILD/$variant"
    rm -rf "$dir"; mkdir -p "$dir/res/values"

    "$PYTHON" - "$ROOT/overlay/res/values/config.xml.in" "$dir/res/values/config.xml" \
        "$COEFFS" "$force" <<'PYGEN'
import sys
src, dst, coeffs, force = sys.argv[1:5]
with open(src, encoding="utf-8") as fh:
    text = fh.read()
text = text.replace("@NIGHT_COEFFICIENTS@", coeffs).replace("@FORCE_AVAILABLE@", force)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(text)
PYGEN

    sed "s/@VERSION@/$VERSION/" "$ROOT/overlay/AndroidManifest.xml" > "$dir/AndroidManifest.xml"

    "$AAPT2" compile --dir "$dir/res" -o "$dir/res.zip" >/dev/null
    "$AAPT2" link \
        -I "$ANDROID_JAR" \
        --manifest "$dir/AndroidManifest.xml" \
        -o "$dir/unsigned.apk" \
        "$dir/res.zip" >/dev/null

    "$ZIPALIGN" -f -p 4 "$dir/unsigned.apk" "$dir/aligned.apk" >/dev/null
    "$APKSIGNER" sign \
        --ks "$KEYSTORE" --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
        --ks-key-alias lune \
        --out "$out" "$dir/aligned.apk" >/dev/null
    say "built $(basename "$out") ($(wc -c < "$out") bytes)"
}

# ---------------------------------------------------------------------------
# Signing key
#
# A self-signed key is correct here. An RRO in a system partition is trusted
# because of where it lives, not who signed it, so there is nothing to gain
# from a platform key - and shipping one would be a much worse idea.
# ---------------------------------------------------------------------------

KEYSTORE="$ROOT/tools/lune.keystore"
KSPASS=lunelune

if [ ! -f "$KEYSTORE" ]; then
    say "generating signing key"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KEYSTORE" -storepass "$KSPASS" -keypass "$KSPASS" \
        -alias lune -keyalg RSA -keysize 2048 -validity 10950 \
        -dname "CN=Lune Bridge, O=uraniam9" >/dev/null 2>&1 \
        || die "keytool failed"
fi

mkdir -p "$BUILD/overlays"
build_overlay standard "" "$BUILD/overlays/LuneDisplayBridge.apk"
build_overlay force "$FORCE_BLOCK" "$BUILD/overlays/LuneDisplayBridge-force.apk"

# ---------------------------------------------------------------------------
# Assemble the module zip
# ---------------------------------------------------------------------------

say "assembling module"
STAGE="$BUILD/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -r "$ROOT/module/." "$STAGE/"
mkdir -p "$STAGE/overlays" "$STAGE/system/product/overlay"
cp "$BUILD/overlays/"*.apk "$STAGE/overlays/"
# Placeholder so the mount point exists; customize.sh moves the chosen APK in.
: > "$STAGE/system/product/overlay/.keep"

mkdir -p "$DIST"
ZIP="$DIST/LuneDisplayBridge-v$VERSION.zip"

"$PYTHON" - "$STAGE" "$ZIP" <<'PYZIP'
import os, sys, zipfile, stat
stage, out = sys.argv[1], sys.argv[2]
# Executables need their mode bits preserved through the zip, or the module
# lands on-device without a runnable lunectl.
EXEC = {".sh"}
EXEC_NAMES = {"lunectl", "quietctl", "luned", "lune-probe", "update-binary"}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(stage):
        dirs.sort(); files.sort()
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, stage).replace(os.sep, "/")
            info = zipfile.ZipInfo(rel)
            info.compress_type = zipfile.ZIP_DEFLATED
            executable = os.path.splitext(name)[1] in EXEC or name in EXEC_NAMES
            info.external_attr = (0o755 if executable else 0o644) << 16
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())
print(out)
PYZIP

say "done"
printf '\n    %s\n    %s bytes\n\n' "$ZIP" "$(wc -c < "$ZIP" | tr -d ' ')"
