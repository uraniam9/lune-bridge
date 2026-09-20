#!/system/bin/sh
#
# late_start service. Runs after the framework is up, so `cmd overlay` and
# `settings` are both available.

MODDIR=${0%/*}
export LUNE_MODDIR="$MODDIR"

OVERLAY_PKG=com.soundsoftlab.lune.overlay

# Android 10 and earlier auto-enable a static overlay from a system partition.
# Android 11 dropped static overlays, so from there it has to be enabled
# explicitly. Only act when it is actually disabled: enabling a framework
# overlay forces a configuration change, and doing that on every boot for no
# reason is how modules get a reputation for making phones feel slow.
enable_overlay() {
    _i=0
    while [ "$_i" -lt 30 ]; do
        if cmd overlay list 2>/dev/null | grep -q "$OVERLAY_PKG"; then
            if cmd overlay list 2>/dev/null | grep "$OVERLAY_PKG" | grep -q '^\[x\]'; then
                return 0
            fi
            cmd overlay enable --user 0 "$OVERLAY_PKG" 2>/dev/null \
                || cmd overlay enable "$OVERLAY_PKG" 2>/dev/null
            return $?
        fi
        sleep 2
        _i=$(( _i + 2 ))
    done
    return 1
}

( 
  while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  enable_overlay
  "$MODDIR/bin/luned"
) &
