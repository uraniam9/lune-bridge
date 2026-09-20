# Testing on a device

First time on real hardware. The order below is deliberate: it sets up a way
out *before* it changes anything about your display.

## 0. Before you flash — set up the escape hatch

This module can make a screen very dark. If that happens and you cannot read
the screen, you need a way to fix it that does not involve looking at it.

On the phone: **Settings → About → tap Build number 7 times**, then
**Developer options → USB debugging → on**. Plug in over USB and accept the
"Allow USB debugging?" prompt.

Then, from the computer, confirm both of these work **before** going further:

```bash
adb devices
```

You want a serial followed by `device` — not `unauthorized` (accept the prompt
on the phone) and not `offline` (replug).

```bash
adb shell su -c id
```

You want `uid=0(root)`. Watch the phone — the first time, your superuser app
will ask for permission. Grant it.

If that second command does not print `uid=0`, **stop here.** Without it you
have no remote recovery, and that is the whole point of this step.

Also worth knowing, independent of USB:

- **Magisk safe mode** — hold **Volume Down** during boot. Android boots into
  safe mode and Magisk disables every module.
- `uninstall.sh` restores stock display settings when the module is removed, so
  removing it in the Magisk/KernelSU app is a real fix, not a half one.

## 1. Note what your device is

Useful later, and it tells you what to expect:

```bash
adb shell getprop ro.product.brand
adb shell getprop ro.product.model
adb shell getprop ro.build.version.sdk
```

SDK 31 or higher means Extra Dim exists, so sub-minimum dimming and
flicker-safe mode are available. SDK 28–30 means warmth and the brightness
floor only.

## 2. Copy the module across

```bash
adb push dist/LuneBridge-v2.0.0.zip /sdcard/Download/
```

## 3. Flash it

Easiest is the GUI: open **Magisk** (or **KernelSU** / **APatch**) →
**Modules** → **Install from storage** → pick the ZIP from Downloads.

Command line, if you prefer:

```bash
# Magisk
adb shell su -c "magisk --install-module /sdcard/Download/LuneBridge-v2.0.0.zip"

# KernelSU
adb shell su -c "ksud module install /sdcard/Download/LuneBridge-v2.0.0.zip"
```

Read the install output. It aborts on Android below 9 and warns below 12.

## 4. Reboot

```bash
adb reboot
```

Give it a minute after the lock screen appears. The module's boot service waits
for the framework, probes the device, then clears its failed-boot guard 20
seconds later.

## 5. The one check that matters

```bash
adb shell su -c lunectl status
```

Everything else depends on the `Overlay` block:

```
Overlay
  installed      yes
  warmth         in effect, warm floor 1700K (stock 2596K)
  dimming        in effect, max strength 99% (stock 90%)
```

**`in effect`** — the ROM accepted the overlay. Full range available.

**`NOT in effect`** — the ROM is refusing third-party framework overlays. The
module still works within Android's stock limits (2596K, 90%). This is a
property of the ROM, not a bug, and it is exactly why the module checks
functionally instead of assuming.

Save the output either way:

```bash
adb shell su -c lunectl status > lune-status.txt
```

## 6. Test the features

Do this somewhere dim, so the differences are visible.

**Warmth** — should go deep amber, well past Night Light's normal limit:

```bash
adb shell su -c "lunectl warm 1850"   # candlelight
adb shell su -c "lunectl warm 4082"   # barely tinted
adb shell su -c "lunectl warm off"
```

While 1850K is active, open **Settings → Display → Night Light**. The toggle
should show as on, and the slider should sit at its extreme. That confirms the
module is driving Android's own feature rather than fighting it.

Take a screenshot while warmth is active. **The screenshot should look normal,
untinted.** That is the proof this is compositor-level and not an overlay — an
overlay dimmer bakes itself into every screenshot.

**Dimming** — should go below the brightness slider's usual floor:

```bash
adb shell su -c "lunectl level 30"
adb shell su -c "lunectl level 8"     # darker than the slider allows
adb shell su -c "lunectl level 3"
adb shell su -c "lunectl reset"
```

**Flicker-safe mode** — the interesting one:

```bash
adb shell su -c "lunectl flicker on"
adb shell su -c "lunectl level 8"
```

The screen should look about as dark as before, but the backlight is now being
held higher with the rest taken from the colour matrix. If low brightness
normally gives you eye strain, this is where you would notice it stop.

## 7. Find your PWM knee

The default is a guess and `status` labels it as such. To measure it: in a dark
room, at a low level, look slightly *off* to one side of the screen —
peripheral vision catches flicker far better than looking straight at it. A
phone camera pointed at the screen often shows banding too.

```bash
adb shell su -c "lunectl knee 45"
adb shell su -c "lunectl knee 40"
adb shell su -c "lunectl knee 35"
```

Lower it until flicker stops, then back up to the last comfortable value —
holding the backlight higher than needed costs contrast for nothing.

Once set, it is recorded as `measured` and no shipped profile will override it.
See [DEVICE-PROFILES.md](DEVICE-PROFILES.md) for contributing it back.

## 8. Test Quiet Field

```bash
adb shell su -c quietctl status
```

Check the `Capabilities` line. On Android 14+ you should see all five levers.
Below that, `screen` and `fullscreen` will be named as unavailable — that is
correct, not a failure.

Pick a noisy app you will not miss. Get its package name:

```bash
adb shell pm list packages -3 | grep -i <part-of-the-name>
```

```bash
adb shell su -c "quietctl add com.example.app"
```

Verify the appop actually took, which is the real test — `quietctl` claiming
success and the framework agreeing are different things:

```bash
adb shell su -c "quietctl on"
adb shell su -c "cmd appops get com.example.app android:wake_lock"
```

You want `ignore`. Then lift it and confirm it goes back:

```bash
adb shell su -c "quietctl off"
adb shell su -c "cmd appops get com.example.app android:wake_lock"
```

You want `default` — not `allow`. `default` hands the decision back to the
framework, so an app the user themselves denied stays denied.

**Quiet hours.** Set a window that includes right now, so you can see it engage
within a minute:

```bash
adb shell su -c "quietctl window 0000-2359"
```

Check that Do Not Disturb came on in the status bar, then confirm alarms are
still allowed — this is the failure people never forgive:

```bash
adb shell su -c "cmd notification set_dnd priority"
```

Set an alarm a minute out and confirm it fires. Then clear the window:

```bash
adb shell su -c "quietctl window off"
```

**Release everything** when you are done testing:

```bash
adb shell su -c "quietctl reset"
```

## 9. Test the app integration

In SonoLune: **Labs → Screen & rendering**. A **Lune Bridge** switch
appears only if the module is installed.

Turn it on. Your superuser app will prompt — grant it. The subtitle then reports
what the probe found, including the honest case where a ROM is still clamping.

With it on, the app's warmth and dimming should route through the compositor.
The check: **take a screenshot with the app's light active.** Previously the
matte overlay would darken the screenshot. Now it should come out clean.

If Extra Dim exists, a **Flicker-safe dimming** switch appears underneath.

Turn the main switch off again and confirm the app goes back to its overlay
without a reboot.

## 10. Undo everything

```bash
adb shell su -c "lunectl reset"
```

Or remove the module in Magisk/KernelSU and reboot — `uninstall.sh` restores
stock display settings on the way out.

## If the screen is too dark to read

```bash
adb shell su -c "lunectl reset"
```

If that does not do it:

```bash
adb shell su -c "settings put system screen_brightness 180"
adb shell su -c "settings put secure reduce_bright_colors_activated 0"
adb shell su -c "settings put secure night_display_activated 0"
```

If the phone will not boot properly at all, hold **Volume Down** during boot for
safe mode, then remove the module.

## What to report

```bash
adb shell su -c lunectl status > lune-status.txt
adb shell su -c quietctl status > quiet-status.txt
adb shell su -c "cat /data/adb/lune/log" > lune-log.txt
```

Those two files, plus your measured knee and anything that looked wrong. They
contain device model, Android version and detected capabilities — no accounts,
no identifiers, nothing personal.
