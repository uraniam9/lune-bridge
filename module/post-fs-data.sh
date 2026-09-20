#!/system/bin/sh
#
# Runs early, before the framework starts. Nothing here touches the display -
# the only job is making sure the runtime has somewhere to write, and that the
# binaries are executable after an install that did not preserve the mode bits.

MODDIR=${0%/*}

mkdir -p /data/adb/lune
chmod 700 /data/adb/lune
chmod 755 "$MODDIR"/bin/* 2>/dev/null
