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

**Flicker-safe mode** — the interesting one, and the one claim in this module
that nothing but a person looking at a screen can confirm. Do it as a real A/B,
in a dark room, with your eyes adjusted. Level 3 is where PWM is worst:

```bash
adb shell su -c "lunectl level 3"
adb shell su -c "lunectl flicker off"    # A
```

Look slightly off to one side of the screen for a few seconds. Peripheral
vision catches flicker far better than looking straight at it.

**The test that does not depend on how your eyes feel.** Whether a screen gives
you a headache is subjective and slow. Whether it is strobing is neither. Wave
a finger or a pen quickly back and forth a few inches in front of the screen
and watch the trail it leaves:

- **Several separate, frozen copies of your finger**, like a stop-motion trail,
  means the backlight is switching on and off. That is PWM, and the gaps you
  are seeing are the screen being dark.
- **One smooth continuous blur** means the light is steady.

Do it at the same brightness with flicker-safe off, then on. If the trail goes
from stepped to smooth, the mode works on your panel, and you have an answer
in ten seconds that does not require sitting there waiting for a headache.

A phone camera pointed at the screen is the other objective check: record a
slow-motion video and look for dark bands rolling through the frame. They
appear under PWM and vanish without it.

```bash
adb shell su -c "lunectl flicker on"     # B
```

Same glance, same spot. Then switch back and forth a few times, because the
first comparison is the least reliable one.

What you are looking for in B: the screen is about as dark as in A, but the
strobing is gone, because the backlight is being held higher and the rest of
the dimming is coming from the colour matrix. What you may also notice is
slightly flatter contrast in dark scenes, which is the stated cost.

Three outcomes, all worth reporting:

- **B is visibly calmer than A.** The mechanism works on your panel.
- **No difference either way.** Your panel may not use PWM at these levels, or
  the knee is set too low to be doing anything. Check `lunectl status` for the
  floor it is holding and try raising the knee.
- **B is not as dark as A.** The knee is higher than it needs to be. Lower it,
  per the next section.

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

## 9. Check the WebUI controls

These four were fixed after the first round of on-device testing and have not
been confirmed on hardware since. They are in 2.0.0 as released, so this is
verification rather than a pending change. Three minutes with the panel open
settles it.

Open the module's WebUI from KernelSU, APatch or MMRL. On plain Magisk 27+, the
module's **Action** button shows the same panel.

**Hold to reset.** Press and hold the reset control for the full countdown
without lifting. It should complete and clear every display setting. The
earlier version aborted the instant a finger moved, because the WebView claimed
the gesture as a scroll and fired `pointercancel`. If it still aborts, say
which manager's WebView you used, since that is the variable that differs.

**PWM knee gating.** With **Flicker-safe** off, the knee control should be
visibly inactive. Turning flicker on should enable it. A disabled control
should say why rather than ignoring the tap.

**DND toggle.** Toggle Do Not Disturb from the panel and confirm the system DND
state actually changes in the status bar, not just in the UI. Then set an alarm
a minute out and confirm it still fires: DND is set to `priority`, never `none`,
so it should.

**Custom time.** Set a quiet window with the custom picker, including an
overnight one such as 2100 to 0800. It should be accepted and read back
correctly. The earlier failure was silent, because the WebView returned
"09:00 PM" where the parser expected "21:00".

Then confirm the UI and the shell agree:

```bash
adb shell su -c "lunectl status"
```

The floor percentage the panel shows and the one `status` reports should match
exactly. They disagreed once, because the UI rounded where the shell truncates.

## 10. Test the app integration

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

## 11. Undo everything

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
