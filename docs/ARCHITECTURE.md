# Architecture

## The idea

Android already has everything needed for a warm, very dim, flicker-free
screen. All of it runs in the compositor, applied as a colour matrix by the
hardware composer before anything reaches the panel. None of it needs an
overlay window, an accessibility service, or a permission the user has to be
talked into.

The capabilities are just clamped, by constants in `framework-res`:

| Resource | Stock | Lune | Effect |
|---|---|---|---|
| `config_nightDisplayColorTemperatureMin` | 2596 | 1700 | warmth reaches candlelight |
| `config_nightDisplayColorTemperatureCoefficients` | fitted 2596–4082K | refitted 1700–4082K | the new range is actually correct |
| `config_reduceBrightColorsStrengthMax` | 90 | 99 | ~2.6× more dimming headroom |
| `config_reduceBrightColorsStrengthMin` | 25 | 0 | dimming starts from nothing |
| `config_screenBrightnessSettingMinimumFloat` | -2 (defer) | 0.0 | slider reaches the panel minimum |
| `config_screenBrightnessSettingMinimum` | 10 | 1 | same, on legacy paths |

So the module is, at heart, one Runtime Resource Overlay plus a thin driver.

## Why an RRO and not `service call SurfaceFlinger`

Poking SurfaceFlinger's colour transform directly is the usual approach in this
space. It is fragile: the transaction code changes between Android versions,
the effect is lost on every SurfaceFlinger restart, and nothing else in the
system knows it happened — so the Settings toggles show stale state.

Changing the framework's limits instead means the system's *own* Night Light
and Extra Dim do the work. They persist across reboots on their own, they
survive SurfaceFlinger restarts, the Settings UI stays truthful, and Quick
Settings tiles keep working. Lune sets a value and gets out of the way.

That is also why the daemon does almost nothing.

## Components

```
overlay/                RRO source. Built into two variants.
tools/coefficients.py   Derives and validates the colour ramp.
tools/build.sh          Compiles, signs, assembles. Gated on validation.
module/bin/lune-probe   Capability detection.
module/bin/lunectl      The entire public interface.
module/bin/luned        Boot service. Deliberately minimal.
module/lib/core.sh      Shared helpers, fixed-point maths.
module/webroot/         WebUI for KernelSU / APatch / MMRL.
```

### The colour ramp

`ColorDisplayService` evaluates `a·T² + b·T + c` per channel and loads the
result as a diagonal 3×3. AOSP fits those quadratics over 2596–4082K only.

Widening the range without refitting evaluates the quadratic outside its
domain. At 1700K the stock curve still reports 26% blue — visibly wrong, and
the reason "just lower the Min" tweaks look washed out rather than warm.

A quadratic has three degrees of freedom and cannot both hit true candlelight
at 1700K and reproduce AOSP's curve across the old range. This was measured,
not assumed: a weighted least-squares fit over the widened range drifts 0.04
inside the stock band *and* goes negative at the floor. So the three degrees of
freedom are spent deliberately:

1. **Exact at 4082K** — the warm ceiling is bit-identical to stock.
2. **Exact at the new floor** — the true blackbody value, gamma-encoded and
   clipped to the sRGB gamut. Below ~1900K a blackbody is outside what an sRGB
   panel can show; zero blue is the honest answer, not a negative one.
3. **Vertex pinned at 4082K** — forces monotonicity. Without this the parabola
   turns over inside the range and blue starts *rising* as you warm past a
   point, which reads as a bug.

Gamma-encoded, not linear: a hypothesis search against AOSP's own published
curve puts gamma-2.4 at a 6500K white point nearly four times closer than
linear sRGB, consistent with the colour transform acting on non-linear
framebuffer values. `coefficients.py --check` prints that comparison.

The generator audits its own output — non-negative, monotonic, drift against
AOSP — and `build.sh` aborts on failure. A bad ramp cannot reach a release.

### Flicker-safe mode

PWM-dimmed OLED panels strobe harder the lower the backlight goes. Vendor "DC
dimming" fixes this in the kernel, but it is per-device, undocumented, and
absent on most hardware.

The insight is that the strobe is a property of the *backlight*, not of the
brightness you perceive. So do not take the brightness out of the backlight:

```
target below the knee  →  backlight = knee
                          colour matrix = target / knee
```

The backlight stays in its well-behaved region; the rest of the dimming comes
from the colour matrix, which does not strobe at all. This needs no vendor
support and works on any device with Extra Dim.

It costs some contrast in dark scenes, and on OLED it uses slightly more power
than simply lowering the backlight would. Both are stated in the UI rather than
hidden.

The knee is panel-specific and Lune does not pretend to know it. The default is
labelled a guess; `lunectl knee` records a measured one.

### The daemon

`luned` handles two things and then sleeps:

- the **failed-boot guard** — set a flag before applying, clear it 20 seconds
  after the framework is up. A boot that begins with the flag still set means
  the last boot did not finish, so Lune clears its settings and stands down.
- the **raw panel override**, the only setting the framework will fight over.
  `DisplayPowerController` rewrites the backlight node on every wake and
  ambient change, so if that override is active the daemon puts the value back,
  polling once a second. If it is not active — the normal case — the daemon
  sleeps in 30-second increments and costs nothing.

Everything else persists through `settings`, which the framework restores by
itself. There is no polling loop for warmth or dimming because there is nothing
to hold up.

### Probing

There is no public registry of display sysfs layouts, and vendor paths differ
between models from the same manufacturer. So the probe looks for what is
present rather than trusting a table, and follows one rule: **never write to a
node it does not understand.** Vendor DC-dimming nodes are reported; enabling
one is left to the user or a device profile.

### Verification

An overlay can be installed, enabled, listed by `cmd overlay list`, and still
not be in effect — wrong partition policy, an OEM `overlayable` block, a ROM
that rebuilds its own idmaps.

So Lune does not check whether the overlay is installed. It asks the framework
to store 1700K, reads the value back, and reports what it finds. If the ROM is
still clamping, `status` says so plainly.

## Quiet Field

The same idea applied to attention: Android already has the mechanisms, they
are just not exposed as a coherent feature.

The original concept for this suite assumed LSPosed hooks would be needed.
They are not, and finding that out changed the design. Everything below is
appops and `cmd notification` — documented interfaces that survive ROM updates
and behave identically on a Pixel and on a heavily skinned OEM build. An Xposed
module hooking `NotificationManagerService` breaks every time a method
signature moves. This cannot break that way, because it hooks nothing.

### Three tiers, cheapest first

**1. appops.** A permission the app simply no longer has. Free, instant,
enforced by the framework, and persisted by the framework across reboots — so
there is nothing to hold up and no loop to run.

| Lever | Op | Since |
|---|---|---|
| `wake` | `android:wake_lock` | always |
| `screen` | `android:turn_screen_on` | Android 14 |
| `fullscreen` | `android:use_full_screen_intent` | Android 14 |
| `vibrate` | `android:vibrate` | always |
| `notify` | `android:post_notification` | always |

Names come from `AppOpsManager`'s `OPSTR_` constants, read from AOSP rather
than from a forum post. Availability is **probed** — `cmd appops get` on an
unknown op fails, and that failure is the detection — so the module is never
wrong about a backporting ROM the way an SDK-number check would be.

`ignore`, never `deny`. `ignore` makes the framework quietly pretend the call
succeeded; `deny` throws a `SecurityException`. Quieting an app should not
crash it, because a crashing app is noisier than the notification was.

Lifting sets `default`, not `allow` — an app the user themselves denied stays
denied. The module returns the decision to the framework rather than taking it.

**2. Do Not Disturb windows.** `cmd notification set_dnd priority` on a
schedule, with `allow_dnd` as a per-app bypass list.

`priority` rather than `none` is deliberate: it keeps alarms working. A
quiet-hours feature that eats someone's alarm has done more harm than every
notification it silenced, and that is the failure people never forgive.

**3. The watcher.** The only part that is not free. `cmd notification list`
gives keys, `get` dumps the record, `snooze` removes it. It is opt-in, and it
only ever looks at apps the user explicitly added — a watcher with global reach
is a watcher that eventually eats a two-factor code.

Two costs, both stated in the UI rather than hidden: it polls, so a matching
notification is briefly visible before it goes, and polling uses battery.
Removing it before it is posted would require hooking, which is the thing this
module exists to avoid.

### Windows that cross midnight

`2100-0800` has to mean "tonight through tomorrow morning", not "never". A
naive `start <= now < end` gives you never. So:

```
start < end   ->  now >= start && now < end
start > end   ->  now >= start || now < end     (overnight)
```

All integer minutes past midnight. Two further traps the tests pin down: `08`
and `09` are octal errors in POSIX arithmetic, so the parser strips leading
zeros arithmetically rather than feeding them to `$(( ))`; and a malformed
window returns an error rather than a number, because a silently mis-parsed
window means the wrong hours of someone's night.

### Cost when idle

`quiet_interval()` scales the scheduler's cadence to what is configured: an
hour when nothing is, five minutes with rules but no schedule, a minute during
quiet hours, and the watcher's own interval only when the watcher is on. A user
who only ever wanted the display half pays nothing for a scheduler with nothing
to schedule.

### Uninstalling

`uninstall.sh` lifts every appop it set. An app left on `ignore` after the
module is gone stays broken forever, with nothing left on the device to explain
why. That is not a courtesy — it is the difference between a removable module
and a permanent change to someone's phone.

## Why the RRO can override these resources

AOSP's `framework-res` ships no `<overlayable>` block, so the `config_*`
resources above are not behind a policy gate and the overlay needs no
`targetName`. Trust comes from the partition: the APK installs to
`/system/product/overlay/`, which gives it product policy.

`android:isStatic` is honoured up to Android 10 and ignored from Android 11, so
`service.sh` runs `cmd overlay enable` as the fallback — but only when the
overlay is actually disabled, because enabling a framework overlay forces a
configuration change and doing that on every boot for no reason is how modules
get a reputation for making phones feel slow.

A ROM that adds its own `overlayable` to `framework-res` can still refuse the
overlay. That is what the functional check above is for.
