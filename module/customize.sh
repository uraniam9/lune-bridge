#!/system/bin/sh
#
# Install-time setup. Magisk sources this with MODPATH, API, ARCH and the
# ui_print/abort helpers already defined.

SKIPUNZIP=0

ui_print " "
ui_print "  Lune Bridge 2.0.0"
ui_print "  ------------------------------------"

if [ "$API" -lt 28 ]; then
    ui_print "! Needs Android 9 (API 28) or newer."
    ui_print "! This device reports API $API."
    abort   "! Aborting."
fi

# Extra Dim is the mechanism used to dim below the panel minimum, and it only
# exists from Android 12. Everything else still works without it, so this is a
# warning rather than a hard stop.
if [ "$API" -lt 31 ]; then
    ui_print "- Android 12+ is needed for dimming below the panel minimum."
    ui_print "  Warmth and flicker-safe mode will still work."
fi

# The default overlay leaves config_nightDisplayAvailable alone. A few OEM
# ROMs turn Night Light or Extra Dim off outright, and forcing them on is only
# safe where the hardware really does accelerate the colour transform - so it
# is opt-in rather than a guess made on the user's behalf.
if [ -f /data/adb/lune/force-availability ]; then
    if [ -f "$MODPATH/overlays/LuneDisplayBridge-force.apk" ]; then
        ui_print "- Using the force-availability overlay (you asked for it)"
        mv "$MODPATH/overlays/LuneDisplayBridge-force.apk" \
           "$MODPATH/system/product/overlay/LuneDisplayBridge.apk"
    fi
else
    mv "$MODPATH/overlays/LuneDisplayBridge.apk" \
       "$MODPATH/system/product/overlay/LuneDisplayBridge.apk" 2>/dev/null
fi
rm -rf "$MODPATH/overlays"

mkdir -p /data/adb/lune
chmod 700 /data/adb/lune

# Seed the re-engagement patterns on first install only. On an upgrade the
# user's edits are theirs to keep; `quietctl reset-patterns` restores ours.
if [ ! -f /data/adb/lune/quiet.patterns ]; then
    cp "$MODPATH/patterns/reengagement.txt" /data/adb/lune/quiet.patterns
    ui_print "- Installed starter re-engagement patterns"
else
    ui_print "- Kept your existing re-engagement patterns"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/system/bin/lunectl" 0 0 0755
set_perm "$MODPATH/system/bin/quietctl" 0 0 0755
set_perm "$MODPATH/system/product/overlay/LuneDisplayBridge.apk" 0 0 0644 u:object_r:vendor_overlay_file:s0 2>/dev/null \
    || set_perm "$MODPATH/system/product/overlay/LuneDisplayBridge.apk" 0 0 0644

ui_print " "
ui_print "  Installed. Reboot to activate."
ui_print " "
ui_print "  Display:"
ui_print "    su -c lunectl status       what your device supports"
ui_print "    su -c lunectl warm 1850    candlelight"
ui_print "    su -c lunectl level 8      a readable 3am screen"
ui_print " "
ui_print "  Quiet Field:"
ui_print "    su -c quietctl status      what your device supports"
ui_print "    su -c quietctl add <pkg>   stop an app waking you"
ui_print "    su -c quietctl window 2100-0800"
ui_print " "
ui_print "  Both status commands tell you honestly what actually"
ui_print "  works on this ROM rather than what was installed."
ui_print " "
