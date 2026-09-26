## 2.0.4

**Nothing about what the module does to your display has changed.** This
release is the panel and the docs, and all of it is about using the module
alongside SonoLune.

**While SonoLune is in charge of your display, the panel no longer pretends you
can set it here.** With *Let SonoLune use it* switched on in SonoLune, the app
decides warmth and light level. It sets them again whenever its own light
changes, and every time you open it. The panel still let you drag both sliders,
and SonoLune then put its own values back, which looks exactly like a broken
slider. The Light level, Warmth and Flicker-safe cards are now greyed out while
SonoLune is in charge (it sets flicker-safe mode too, from its Lune Bridge
page), and tapping one tells you where that setting lives. Quiet Field stays
yours to change here: SonoLune only writes it when you tap its own Quiet Field
card, both edit the same list and schedule, and a note on the tab says so.

**The banner says what is actually happening.** It used to show in the red
warning style, as if something had gone wrong, and it sent you to *Labs >
Screen & rendering* in SonoLune, where there is no such switch. It is now a
plain status line, *Driven by SonoLune*, that names the right place, *Let
SonoLune use it* on SonoLune's Lune Bridge page, and it has *Open Light in
SonoLune* and *Open Lune Bridge in SonoLune* buttons.

**Opening SonoLune from the panel lands on the right card.** Its *Open Labs*
button opened SonoLune's Labs page, which SonoLune closes to anyone who does
not have Labs, even though the Lune Bridge card on it is open to everyone. It
is now *Open Lune Bridge in SonoLune*, and it opens SonoLune's own Lune Bridge
page, which is open to everyone, with its switch highlighted.

**The panel says when SonoLune could drive it.** With SonoLune on the phone and
its switch off, the top of the panel now says so, with a button straight to
that switch and an x that closes it for good.

**The panel notices when you switch SonoLune off.** It checked who was in
charge once, when it opened. Turn SonoLune's switch off, come back to the
panel, and it went on showing the old banner and the old values until you
closed it completely. It now checks again when it comes back into view, Quiet
Field included - SonoLune's Lune Bridge page edits the same list, the same
"quiet now" and the same schedule.

**Changing quiet hours no longer switches off a quiet you turned on yourself.**
Setting quiet hours applied the new schedule straight away, so in the daytime
it switched a hand-made quiet off, and clearing them always did. A quiet you
turned on by hand now lasts until the schedule's next start or end; quiet that
the schedule itself turned on still ends when you clear it.

**The flicker knee's advice pointed the wrong way.** It said to lower the knee
until flicker stops, but lowering it is what lets flicker back in: the
backlight is held at the knee. It now says to lower it for a darker minimum
until flicker starts to show, then go back up a step. The testing guide said
the same, and is fixed too.

**The docs point to the right switch.** The README and the testing guide sent
people to *Labs > Screen & rendering* too. Both now point to SonoLune's Lune
Bridge page. The README also no longer claims nothing at all is drawn over your
screen: warmth and dimming are not, but SonoLune's other effects, like grain
and veil, still are.

**SonoLune 2.4.4 can find this module.** Earlier versions looked for it in a
folder Android keeps closed to apps, so the Lune Bridge switch never appeared,
even with the module installed and working. If you never saw that switch, that
is why: update SonoLune. Its Lune Bridge page also has an *Add to home screen*
button now, for an icon that opens straight to it.

**Integrated with SonoLune, start to finish.** Warmth, dimming, Quiet Field -
this whole release is about making that pairing honest. If you found your way
here from the app and want to know what else it does, it's at
[sonolune.app](https://sonolune.app). Enjoy.

## 2.0.3

**The panel now tells you when there is a newer release.** 2.0.2 fixed a bug
that could leave a lock screen unreadable, and the people who needed it had no
way of knowing it existed. That is a poor way to ship a fix.

It shows the new version, links its release notes, and has a Skip button for
when you have heard enough about that one.

Where the network is concerned, the rules it follows:

- It runs **when you open the panel**, never from the daemon. A module whose
  argument is that it stays out of your way has no business talking to the
  internet while you are asleep.
- The answer is **cached on the device for twelve hours**, so opening the panel
  repeatedly does not mean repeatedly asking GitHub.
- It fetches **one static file** from the repo. It sends no identifiers of its
  own: no device ID, no install ID, nothing about your phone. Nothing is
  recorded anywhere but on your phone.
- `lunectl update off` **stops it for good**, and `lunectl update` runs it by
  hand whenever you want.

A reply that is not the feed is discarded rather than believed, so a captive
portal login page cannot turn into "you are out of date".

## 2.0.2

**Fixes a bug that could leave you looking at a lock screen too dark to read.**
If you hit this, boot into Android's safe mode (hold Volume Down through the
boot animation) to get back in, then update.

At boot the module probes what the framework still clamps, and it does that by
writing a value and reading back what was stored. It then puts the old value
back. When the setting had never been written on that device there was no old
value to put back, and instead of clearing the key it left its own test value
sitting there: Extra Dim strength at 95, the warm floor at 1700K.

On a device where Extra Dim or Night Light was already switched on, that took
effect on the next boot. The screen came up at roughly a twentieth of its
normal light, or deep amber, on a lock screen the owner then could not read
well enough to unlock. The module was working exactly as designed and the phone
was unusable, which is the worst shape a bug can take.

The probe now clears a key it found empty rather than leaving a value behind.
Two tests cover it, and both fail against the old code.

**The boot probe now runs only when something changed.** What it measures moves
only when the ROM or the module does, so it is keyed on both and skipped
otherwise. Writing to display settings on every single boot is what turned one
mistake into a thing that happened every time. `lunectl probe` still re-runs it
whenever you want.

Reported independently by two people on two different root managers, which is
what made it obvious this was the module rather than anything device-specific.

## 2.0.1

Fixes found by using it on a phone rather than reading it.

**Do Not Disturb ignored the preference while quiet mode was running**, in
both directions. Switching it on mid-quiet did nothing until the next entry,
which for an overnight window is the following night; switching it off left DND
on with the only control for it now reading "off" and `quietctl reset` the only
way out. Both had the same shape: a preference read at one moment to decide
something that happens at another. Quiet mode now records that it was the one
that turned DND on and acts on that record, so the preference takes effect when
you change it. DND you switched on yourself is still left alone.

**The manual quiet toggle lost to the scheduler.** Inside quiet hours the next
tick re-applied whatever the window said, so switching quiet mode off by hand
lasted about twenty seconds. A manual tap is now an override that holds until
the window's own answer changes, which is the next window edge.

**Setting a schedule looked like it did something else.** A window containing
the current time starts quiet mode immediately, which is the point of a
schedule, but nothing said so. It does now, and the custom pickers no longer
look like they have applied when they have not: Set marks itself while it is
holding something unsaved. Presets still apply on tap, which is the difference
that was invisible before.

**Do Not Disturb could not be switched off.** Turning the DND preference off
while quiet mode was active left DND on, with `quietctl reset` the only way
out. Two faults compounded: `quietctl dnd off` only wrote the config and never
released a hold it was already holding, and the lift on leaving quiet mode was
gated on re-reading that same preference, so once it said off the lift was
skipped for good. Quiet mode now records that it was the one that turned DND
on and lifts on that record. DND you switched on yourself is still left alone.

**A gated PWM knee said nothing when tapped.** It was `disabled`, and a
disabled control swallows the event, so the explanation never fired and the
knee read as broken rather than off-limits.

**Buttons in rows and lists were sized for a mouse.** Set, the DND toggle and
the per-app buttons now clear 36px.

**An app quieted and allowed through at once resolved in silence.** Both rows
now say which way it resolves and which levers do the winning, including the
case where the `notify` lever makes the allow do nothing at all.

**Quiet hours threw away the times typed into them** when the schedule was
switched off, so turning it back on meant setting both pickers again.

**Warmth "Off" now says so when warmth is already off**, instead of making a
round trip and changing nothing visible.

Added:

- Press and hold anywhere on the panel for two seconds to reset. The reset
  button is the way back from a screen too dark to read, which is exactly when
  it cannot be found.
- **Report a bug**, **Request a feature** and **Share my PWM knee** in About,
  opening the issue forms directly.
- The SonoLune card can be dismissed for good, and points at the half of the
  app that matches the tab you are on. A small "by SonoLune" stays beside the
  title once the card is gone.

## 2.0.0

Adds the Quiet Field suite. The module is now called **Lune Bridge** rather
than Lune Display Bridge, since it is no longer only about the display. The
module id changed with it, from `lune_display_bridge` to `lune_bridge`.

**If you ran a build from before the rename, upgrading does not replace it.**
Magisk and KernelSU key modules by id, so the old one stays installed
alongside, and its copies of `lunectl` and `quietctl` in `/system/bin` may be
the ones you get on the command line. Check with
`su -c "ls -d /data/adb/modules/lune_*"`, and if `lune_display_bridge` is listed,
remove it.

**No Xposed, anywhere.** The original concept for Quiet Field assumed LSPosed
hooks would be needed. They are not. Everything below is appops and
`cmd notification` - documented interfaces that survive ROM updates and behave
the same on a Pixel and on a heavily skinned OEM build.

- Per-app levers via appops: `wake_lock`, `turn_screen_on`,
  `use_full_screen_intent`, `vibrate`, `post_notification`. Availability is
  probed per device rather than inferred from the SDK number.
- Quiet windows on a schedule, including windows that cross midnight. Do Not
  Disturb is set to *priority*, not total silence, so alarms still fire.
- Per-app Do Not Disturb bypass, so the people who matter still get through.
- Opt-in re-engagement watcher that snoozes notifications matching a pattern
  list, and only for apps you explicitly added. Ships 27 starter patterns.
  Honest about its two costs: it polls, so matches flash briefly first, and
  polling uses battery.
- `quietctl` CLI, and a Quiet Field tab in the WebUI with an app picker.
- Scheduler cadence scales with use - an hour when nothing is configured, a
  minute during quiet hours - so the display-only user pays nothing for it.
- `uninstall.sh` now lifts every appop it set. An app left on `ignore` after
  the module is gone would stay broken with nothing left to explain why.
- 89 tests, up from 38. New coverage for overnight windows, the `08`/`09`
  octal parsing trap, lever mapping, and a check that no shipped pattern
  matches an ordinary message.

Fixed a latent bug where `conf_get`/`cap_get`/`qconf_get` referenced an unbound
`$2` when called without a default. Harmless under Android's shell, caught by
the stricter test harness.

## 1.0.0

First release.

- Night Light warm floor lowered from 2596K to 1700K, with the colour ramp
  refitted rather than extrapolated. Generator validates non-negativity,
  monotonicity and drift against AOSP, and the build refuses a ramp that fails.
- Extra Dim strength range widened from 25-90% to 0-99%, roughly 2.6x more
  dimming headroom below the panel minimum.
- `config_screenBrightnessSettingMinimumFloat` lowered to 0.0 so the ordinary
  brightness slider reaches the panel's real minimum.
- Flicker-safe mode: holds the backlight above the panel's PWM knee and takes
  the remaining dimming from the colour matrix, so low brightness does not
  strobe. Works without any vendor DC-dimming kernel support.
- Functional overlay verification - status reports whether the overlay is
  actually in effect, not merely installed.
- Capability probe that detects rather than assumes, and never writes to a
  vendor display node it does not recognise.
- Failed-boot guard, and an uninstall that restores stock display settings.
- WebUI for KernelSU / APatch / MMRL, and an action button for Magisk 27+.
