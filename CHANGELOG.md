# Changelog

## 2.0.0

Adds the Quiet Field suite. The module is now called **Lune Bridge** rather
than Lune Display Bridge, since it is no longer only about the display. The
module id is unchanged, so this is an in-place upgrade.

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
