# Lune Bridge

A Magisk / KernelSU / APatch module in two halves: **Display**, which gives
Android's display pipeline the range it already has the hardware for, and
**Quiet Field**, which stops apps taking your attention when you didn't offer
it.

Both work the same way. They drive mechanisms Android already has instead of
inventing new ones. **Neither needs Xposed, and that includes LSPosed.** Nothing here
hooks a process or patches a framework method, which is why it survives ROM
updates and behaves the same on a Pixel and on a heavily skinned OEM build.

```
su -c lunectl warm 1850            # candlelight. Stock Android stops at 2596K.
su -c lunectl level 8              # readable at 3am, below the panel's minimum.
su -c lunectl flicker on           # stop the PWM strobe low brightness causes.

su -c quietctl add com.some.app    # no wake locks, no screen-on, no takeover.
su -c quietctl window 2100-0800    # quiet hours. Alarms still work.
```

---

## Display

Android can already tint your screen to candlelight and dim it far below the
brightness slider's floor. It does both in the compositor, with no overlay
window and no accessibility service. It just refuses to go that far. The limits
are constants in `framework-res`, and they are set conservatively.

This module moves those limits, correctly.

---

## Why this is not another screen-dimmer

Every no-root dimming app works the same way: draw a translucent black window
over everything. That approach has permanent costs. It can't cover the status
bar reliably, it blacks out in screenshots and screen recordings, it's
excluded from secure surfaces, it crushes contrast because it's adding black
rather than emitting less light, and it needs an accessibility service or an
always-on overlay permission that users are right to be suspicious of.

Android's own mechanisms have none of those problems, because they run in the
compositor before anything reaches the panel:

| | Overlay apps | Lune |
|---|---|---|
| Lock screen, status bar | partial | covered |
| Screenshots / recording | blacked out | clean |
| Secure surfaces (banking, DRM) | excluded | covered |
| Contrast at low light | crushed | preserved |
| Permissions needed | accessibility or overlay | none, it is a root module |
| Cost | an extra composited layer | none, it is a colour matrix |

Lune doesn't add a mechanism. It unlocks the ones that are already there.

---

## Display: the three things it changes

### 1. Warmth down to 1700K, with a refitted colour ramp

Night Light stops at 2596K. Lowering that limit is a one-line overlay and
plenty of tweaks do exactly that. What you get is a washed-out tint rather than
candlelight, and the reason is worth knowing.

`ColorDisplayService` computes the tint from a quadratic, `a·T² + b·T + c`, per
channel. AOSP fits that quadratic over 2596–4082K **only**. Evaluate it at
1700K and it still reports 26% blue, which is nothing like a 1700K blackbody.
The curve is being used far outside its domain.

So Lune refits it. [`tools/coefficients.py`](tools/coefficients.py) derives a
new ramp from the Planckian locus, and constrains it so that:

- it is **exact at 4082K**, so the top of the slider is untouched;
- it is **exact at the new floor**, at the true gamut-clipped blackbody value;
- it is **monotonic**, so warming never starts adding blue back. An
  unconstrained least-squares fit turns over inside the range and does exactly
  that, which reads as a bug;
- it **never goes negative**, which would invert a channel instead of warming it.

The generator validates its own output and the build refuses to ship a ramp
that fails. Cost of the refit: green stays within 0.03 of stock inside the old
range, blue within 0.05. Run `python3 tools/coefficients.py` to see the report.

### 2. Dimming below the panel minimum, without an overlay

Android 12 added "Extra Dim", which multiplies the framebuffer down through the
hardware colour matrix. It's the right mechanism and it's already on your
phone. It's also clamped to 25–90% strength.

At 90% the stock ramp leaves 14% of the signal. Lune raises the ceiling to 99%,
which leaves 5.4%, roughly another 2.6× darker. That's the difference between
"dim" and "readable at 3am without waking yourself up".

Lune also drops `config_screenBrightnessSettingMinimumFloat` to `0.0`, which is
what the AOSP comment on that resource explicitly suggests, so the ordinary
brightness slider reaches the panel's real minimum first.

### 3. Flicker-safe mode

Most OLED panels dim by PWM: below a certain backlight level the driver strobes
the panel, and for a significant minority of people that strobe causes eye
strain, headaches and nausea. Vendor "DC dimming" toggles fix it, but they are
per-device kernel features with no standard interface, and most devices don't
have one at all.

Flicker-safe mode doesn't need one. It holds the backlight **above** the knee
where strobing gets bad, and takes the remaining dimming out of the colour
matrix instead, which doesn't strobe. You get the brightness you asked for
without the flicker that usually comes with it.

```
lunectl flicker on
lunectl knee 40      # lower until the flicker stops being visible
```

The default knee is a guess, and `lunectl status` says so. Measuring it is one
slider drag.

---

## Quiet Field

Attention control, built the same way: no hooks, no Xposed, no accessibility
service. Just permissions apps no longer have, and Android's own Do Not
Disturb on a schedule.

### Levers

Each one is an appop: a permission the framework simply stops granting.
Instant, free, enforced by the system, and it survives reboots by itself.

| Lever | What the app can no longer do | Needs |
|---|---|---|
| `wake` | hold a wake lock, so it cannot keep the CPU or screen up | any Android |
| `screen` | turn your screen on | Android 14+ |
| `fullscreen` | take the whole screen over with a notification | Android 14+ |
| `vibrate` | buzz | any Android |
| `notify` | post notifications at all (blunt, opt in per app) | any Android |

```
quietctl add com.example.social                    # wake, screen, fullscreen
quietctl add com.example.news wake,fullscreen,vibrate
quietctl list
```

Availability is **probed on your device**, not guessed from the SDK number, and
`quietctl status` names any lever your Android version doesn't have.

Levers are set to `ignore`, not `deny`. `ignore` makes the framework quietly
pretend the call worked; `deny` throws a `SecurityException` and takes badly
written apps down with it. Quieting an app should not crash it. A crashing app
is noisier than the notification ever was.

### Quiet hours

```
quietctl window 2100-0800
quietctl allow com.example.messages
```

Windows that cross midnight work properly. Do Not Disturb is set to
**priority**, not total silence, so **alarms still go off**. A quiet-hours
feature that eats someone's alarm has done more harm than every notification it
silenced.

Anything on the allow list breaks through: a partner, a parent, your on-call
app.

### The re-engagement watcher (opt-in)

Snoozes notifications matching a pattern list ("we miss you", "your streak is
about to expire", "3 new updates") for apps you added, and **only** for apps
you added.

```
quietctl watch on
quietctl pattern add "your (order|delivery) is"
```

It ships 27 starter patterns, deliberately conservative: a false positive means
a notification you wanted disappeared, which is much worse than one you didn't
want surviving. A test asserts none of them match an ordinary message.

**Two honest costs.** It polls `cmd notification list`, so a matching
notification appears briefly before it goes, and polling uses battery. Removing
them before they are posted would need framework hooks, which is exactly what
this module exists to avoid. Off by default; the UI says both.

### Cost when you are not using it

The scheduler's wake cadence scales with what you have configured: an hour
when nothing is set up, five minutes with rules but no schedule, a minute
during quiet hours. If you only ever wanted the display half, Quiet Field costs
you nothing.

---

## Install

Requires Android 9+ and Magisk 20.4+, KernelSU or APatch. Android 12+ for the
dimming feature specifically.

1. Download `LuneBridge-v2.0.2.zip` from Releases.
2. Flash it in Magisk / KernelSU / APatch.
3. Reboot.
4. `su -c lunectl status`

There's a WebUI. Open the module in KernelSU, APatch or MMRL. On plain
Magisk 27+, the module's **Action** button shows the same report.

### Check it actually worked

```
su -c lunectl status
```

The important lines are under `Overlay`:

```
Overlay
  installed      yes
  warmth         in effect, warm floor 1700K (stock 2596K)
  dimming        in effect, max strength 99% (stock 90%)
```

If it says **NOT in effect**, the overlay installed but this ROM is refusing
third-party framework overlays. Lune tells you that plainly instead of
pretending. Everything still works, just within Android's stock limits.

This check is functional, not cosmetic: Lune asks the framework to store 1700K
and reads the value back. An overlay can be installed, enabled, and listed, and
still not be in effect.

---

## Commands

```
lunectl status                what this device can do, and what is active
lunectl level <1-100|off>     light level, the safe way (use this one)
lunectl warm <kelvin|off>     colour temperature, 1700-4082K
lunectl dim <0-99|off>        dim below the panel minimum, as a percentage
lunectl flicker <on|off>      hold the backlight above its PWM knee
lunectl knee <1-100>          tell Lune where this panel starts flickering
lunectl backlight <raw|auto>  write the panel node directly (advanced)
lunectl probe                 re-run capability detection
lunectl reset                 undo everything
```

`level` is the one to reach for. It decides how to split your request between
panel brightness and the colour matrix, honouring flicker-safe mode if it is on.

```
quietctl status               what this device can do, and what is active
quietctl add <pkg> [levers]   quiet an app (default: wake,screen,fullscreen)
quietctl remove <pkg>         stop quieting it
quietctl list                 apps being quieted, and with which levers
quietctl window <HHMM-HHMM>   quiet hours, e.g. 2100-0800
quietctl on | off             enter or leave quiet mode now
quietctl allow <pkg>          may break through Do Not Disturb
quietctl watch <on|off>       strip re-engagement notifications
quietctl pattern add <regex>  what counts as re-engagement
quietctl stats                what has been blocked
quietctl reset                release everything
```

---

## What it does on your device

Lune probes rather than assumes, because display sysfs layouts aren't
standardised and there's no public registry of them. `lunectl status` reports
what it found.

| Feature | Needs | If unavailable |
|---|---|---|
| Warmth to 1700K | Night Light + overlay in effect | falls back to the stock floor |
| Dim below minimum | Android 12+ Extra Dim | brightness floor still lowered |
| Flicker-safe mode | Extra Dim | unavailable |
| Raw panel control | a writable backlight node | unavailable |
| Vendor DC dimming | a kernel node Lune recognises | reported, never auto-enabled |
| Quiet: wake, vibrate, notify | any Android with root | n/a |
| Quiet: screen, fullscreen | Android 14+ appops | named as missing in `status` |
| Quiet hours + allow list | `cmd notification` access | named as missing in `status` |
| Re-engagement watcher | `cmd notification` access | unavailable |

Lune never writes to a vendor display node it doesn't understand. It reports
what exists and leaves enabling it to you or to a device profile. Poking
unknown display registers is a good way to hand someone a black screen at boot.

---

## Safety

Anything that can make a screen near-black at boot needs a way back that does
not require seeing the screen.

- **Failed-boot guard.** The daemon sets a flag before applying settings and
  clears it 20 seconds after the framework is up. If a boot starts with the
  flag still set, the previous boot didn't finish, so Lune clears its settings
  and stands down.
- **Uninstalling actually undoes it.** `uninstall.sh` puts the display back to
  stock rather than leaving a dim screen and no tool to fix it.
- **Magisk safe mode** (hold Volume Down during boot) disables all modules.
- `lunectl reset` at any time.

---

## Contributing a device profile

The most useful thing you can send is your PWM knee and what your device
exposes. After finding a knee that works:

```
su -c lunectl status > lune-$(getprop ro.product.model).txt
```

Open an issue with that file. See [docs/DEVICE-PROFILES.md](docs/DEVICE-PROFILES.md).

---

## Building

Needs an Android SDK (build-tools + one platform), a JDK, and Python 3.

```bash
./tools/build.sh
```

Produces `dist/LuneBridge-v2.0.2.zip`. The build computes the colour
ramp from source and **refuses to continue if the ramp fails its own
validation**, so a bad curve can't reach a release.

The build also runs [`tools/test-core.sh`](tools/test-core.sh) first, which
exercises the fixed-point arithmetic the runtime uses. Those tests aren't
decoration. They caught a factor-of-ten error in the dimming inversion that
made flicker-safe mode deliver 2% when asked for 45%.

The overlay is self-signed, which is correct here. An RRO in a system partition
is trusted because of where it lives, not because of who signed it. `build.sh` generates a
throwaway key if none exists, and the key is gitignored. For published
releases, keep one key outside the repo and reuse it, so upgrades don't change
the overlay's signature.

---

## Using it from an app

`lunectl` is the stable interface. See [docs/API.md](docs/API.md) for the
contract, exit codes, and a Kotlin example.

---

## How it works

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design, including
why the daemon does almost nothing and why that's deliberate.

First time on hardware? [docs/TESTING.md](docs/TESTING.md) walks through it,
recovery path first.

A copy-paste release announcement for XDA and r/Magisk is in
[docs/RELEASE-POST.md](docs/RELEASE-POST.md).

## SonoLune

Lune Bridge is the root companion to **SonoLune**, a calm-first sleep and focus
app. SonoLune works fine without root. It dims and warms by drawing a matte
over the screen, the way every no-root app has to.

With this module installed, it stops doing that. Warmth and dimming move into
the display pipeline instead: no overlay over your screen, clean screenshots,
secure surfaces covered, and the full 1700K range rather than Android's 2596K
floor. Turn it on in **Labs → Screen & rendering**.

The module stands alone. You don't need the app to use it, and everything
here works from `lunectl` and `quietctl` on their own.

**[sonolune.app](https://sonolune.app)** turns the phone into a calm
environment rather than another thing demanding something from you. It works
offline. No ads, no tracking, no streaks, no data collection.

[SonoLune on Google Play](https://play.google.com/store/apps/details?id=com.soundsoftlab.sonolune)

## Support

Free, and staying that way.

[Buy me a coffee](https://buymeacoffee.com/uraniam9) if it stopped your eyes
hurting at 3am. It goes back into the work, and into the odd second-hand phone
to test on.

The most useful thing you can send is still your PWM knee. It ships as a device
profile, so the next person with your phone gets a measured value instead of a
guess. See [docs/DEVICE-PROFILES.md](docs/DEVICE-PROFILES.md).

Support links live in one place: the `LINKS` block at the top of the script in
`module/webroot/index.html`. A button only renders when its URL is set, so
unfilled entries show nothing rather than a dead link.

## Licence

GPL-3.0 © uraniam9. See [LICENSE](LICENSE).
