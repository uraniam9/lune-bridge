# Shipped device profiles

One file per device, named `<brand>-<model>.prop` (lowercased, spaces and
slashes replaced with hyphens). Only `pwm_knee` is read; everything else is
treated as a comment.

A knee the user measured themselves always wins over a shipped profile.

See ../../docs/DEVICE-PROFILES.md for how to measure and contribute one.
