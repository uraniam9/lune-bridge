#!/system/bin/sh
#
# Runs when the module is removed. Put everything back to stock so that
# uninstalling actually undoes things.
#
# The appops matter most here. An app left with wake_lock or post_notification
# on "ignore" stays broken forever, long after the module that did it is gone,
# and the user has no way left to find out why. Lifting them is not a courtesy,
# it is the difference between a removable module and a permanent change.

MODDIR=${0%/*}

# Display
settings put secure night_display_activated 0 2>/dev/null
settings put secure reduce_bright_colors_activated 0 2>/dev/null
settings put secure reduce_bright_colors_level 50 2>/dev/null
settings put system screen_brightness 102 2>/dev/null

# Quiet Field - hand every quieted app its permissions back.
if [ -f /data/adb/lune/quiet.apps ]; then
    while IFS=: read -r pkg levers; do
        [ -n "$pkg" ] || continue
        for lever in $(echo "$levers" | tr ',' ' '); do
            case "$lever" in
                wake)       op="android:wake_lock" ;;
                screen)     op="android:turn_screen_on" ;;
                fullscreen) op="android:use_full_screen_intent" ;;
                vibrate)    op="android:vibrate" ;;
                notify)     op="android:post_notification" ;;
                *)          continue ;;
            esac
            cmd appops set "$pkg" "$op" default 2>/dev/null
        done
    done < /data/adb/lune/quiet.apps
fi

if [ -f /data/adb/lune/quiet.allow ]; then
    while read -r pkg; do
        [ -n "$pkg" ] && cmd notification disallow_dnd "$pkg" 2>/dev/null
    done < /data/adb/lune/quiet.allow
fi

cmd notification set_dnd off 2>/dev/null

rm -rf /data/adb/lune
