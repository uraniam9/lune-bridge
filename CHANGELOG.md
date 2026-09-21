# Changelog

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
`ls -d /data/adb/modules/lune_*`, and if `lune_display_bridge` is listed,
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
