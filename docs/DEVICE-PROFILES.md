# Device profiles

Almost everything Lune needs, it detects. One thing it cannot: **the PWM knee**
— the backlight percentage below which your panel's strobing becomes
noticeable.

That number is not exposed anywhere. It is a property of the panel and its
driver, and the only instrument that can measure it is a person looking at the
screen. But it is the same for everyone with the same phone, which makes it
exactly the kind of thing worth sharing.

Lune ships with a default of 50% and labels it a guess. `lunectl status` says
`(default)` next to it until someone measures a real one.

## Finding your knee

1. `su -c lunectl flicker on`
2. In a dark room, set a low level: `su -c lunectl level 10`
3. Wave your hand in front of the screen, or look slightly off to one side —
   peripheral vision catches flicker far better than looking straight at it.
   Some people see banding on a phone camera pointed at the screen.
4. Adjust with `su -c lunectl knee 40`, `knee 35`, and so on. Lower it until
   the flicker stops.
5. Go a little lower still, then back up to the last comfortable value —
   holding the backlight higher than necessary costs contrast for nothing.

A knee you set this way is recorded as `measured` and is never overwritten by
a shipped profile.

## Contributing

```
su -c lunectl status > lune-$(getprop ro.product.model).txt
```

Open an issue with that file attached and the knee you settled on. It contains
device model, Android version, detected nodes and capabilities — no accounts,
no identifiers, nothing personal.

If you would rather send a pull request, add a file to `module/profiles/`:

```
module/profiles/<brand>-<model>.prop
```

The name is `ro.product.vendor.brand` and `ro.product.vendor.model`,
lowercased, with spaces and slashes replaced by hyphens. `lunectl status`
prints both on its first line. For example, a Pixel 8 Pro is
`google-pixel-8-pro.prop`.

```properties
# Google Pixel 8 Pro
# Contributed by: <your handle>
# Measured on: Android 15, stock ROM

# Backlight % below which this panel's PWM strobe becomes visible.
pwm_knee=45
```

Only `pwm_knee` is read. Everything else in the file is treated as a comment,
so notes about the panel are welcome.

## What is deliberately not in a profile

Vendor DC-dimming nodes are **detected and reported, never written to**. They
vary between models from the same manufacturer, their accepted values are
undocumented, and writing a wrong value to a display register can leave someone
with a black screen at boot. Lune reports what it found and leaves it there.

If you have a node that you know works on your device, open an issue with the
path and the exact value. That is worth documenting properly before it is worth
automating.

Flicker-safe mode does not depend on any of these nodes. It works on any device
with Extra Dim, which is why it is the recommended fix rather than a fallback.
