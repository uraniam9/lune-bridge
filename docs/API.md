# Using Lune from an app

`lunectl` is the stable interface. An app shells out to it through `su`. There
is no AIDL service, no bound socket and no content provider, because none of
those would survive a module being flashed by someone who is not running your
app — and a root module has no business running a persistent service it does
not need.

## Detecting the module

```
/data/adb/modules/lune_bridge/bin/lunectl version
```

Exits `0` and prints a semver string if Lune is installed and the caller is
root. Anything else means treat it as absent.

Presence of the module is **not** the same as the overlay being in effect. Read
capabilities before advertising a feature.

## Reading capabilities

`/data/adb/lune/caps` is a `key=value` file, one pair per line, rewritten on
every probe. Read it directly rather than parsing `status`, whose layout is for
humans and may change.

| Key | Values | Meaning |
|---|---|---|
| `night_display` | `yes` / `no` | Night Light exists on this device |
| `extra_dim` | `yes` / `no` | Android 12+ Extra Dim exists |
| `overlay_warmth` | `yes` / `no` | the widened warm range is in effect |
| `overlay_dim` | `yes` / `no` | the widened dim range is in effect |
| `warm_floor` | integer K | lowest temperature this device accepts |
| `dim_max` | integer 0–99 | highest dim strength this device accepts |
| `backlight_node` | path or empty | writable panel node, if any |
| `dc_nodes` | space-separated paths | vendor DC-dimming nodes detected |
| `pwm_knee` | integer 1–100 | backlight % below which the panel strobes |
| `pwm_knee_source` | `default` / `measured` | whether the knee is a guess |
| `safe_mode` | `yes` / `no` | Lune stood down after a failed boot |
| `sdk`, `brand`, `device` | strings | device identity |

`warm_floor` is the value to drive a slider's minimum from. Do not hard-code
1700 — on a ROM that refuses the overlay it will be 2596, and a slider that
offers a range the device will clamp is worse than one that tells the truth.

## Current state

`/data/adb/lune/config`, same format.

| Key | Values |
|---|---|
| `level` | `1`–`100` |
| `warm` | Kelvin, or `off` |
| `dim` | `0`–`99` |
| `flicker` | `on` / `off` |
| `backlight_raw` | raw panel value, or empty |

## Commands

All exit `0` on success and non-zero on failure, with a message on stderr
prefixed `lune:`.

```
lunectl level <1-100|off>     split between panel and colour matrix
lunectl warm <kelvin|off>     colour temperature
lunectl dim <0-99|off>        colour-matrix dimming
lunectl flicker <on|off>      flicker-safe mode
lunectl knee <1-100>          record a measured PWM knee
lunectl probe                 re-detect, rewrites caps
lunectl reset                 back to stock
```

Out-of-range values are clamped, not rejected, and the clamp is reported on
stdout. Check `caps` first if you need to know the range in advance.

## Stability

Command names, argument forms and the two `key=value` files are the contract
and follow semver. Human-readable `status` output is not part of it.

## Kotlin

```kotlin
object Lune {
    private const val BIN = "/data/adb/modules/lune_bridge/bin/lunectl"

    private fun su(cmd: String): Pair<Int, String> = try {
        val p = ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor() to out
    } catch (e: Exception) {
        -1 to (e.message ?: "")
    }

    fun isAvailable(): Boolean = su("$BIN version").first == 0

    /** Parses the key=value files the module writes. */
    private fun readKv(path: String): Map<String, String> {
        val (code, out) = su("cat $path")
        if (code != 0) return emptyMap()
        return out.lineSequence().mapNotNull { line ->
            val i = line.indexOf('=')
            if (i > 0) line.substring(0, i).trim() to line.substring(i + 1).trim() else null
        }.toMap()
    }

    fun caps(): Map<String, String> = readKv("/data/adb/lune/caps")

    /**
     * Lowest colour temperature this device will actually accept.
     *
     * Driven from the probe rather than assumed: on a ROM that refuses the
     * overlay this is still 2596, and offering a range the framework will
     * silently clamp is worse than showing the real limit.
     */
    fun warmFloorKelvin(): Int = caps()["warm_floor"]?.toIntOrNull() ?: 2596

    fun setWarm(kelvin: Int) = su("$BIN warm $kelvin")
    fun setWarmOff() = su("$BIN warm off")
    fun setLevel(percent: Int) = su("$BIN level ${percent.coerceIn(1, 100)}")
    fun setFlickerSafe(on: Boolean) = su("$BIN flicker ${if (on) "on" else "off"}")
    fun reset() = su("$BIN reset")
}
```

Each `su` call spawns a process, so do not drive one from a slider's
`onProgressChanged` — debounce to the last value once the gesture settles, the
way the WebUI does.

## Notes from a real integration

Three things that turned out to matter when wiring this into a shipping app.
None are obvious until something goes wrong.

**Never call `su` on the main thread.** The first invocation raises the
superuser app's permission dialog, and the call blocks for as long as that
dialog is on screen — which is unbounded, because it waits on a human. Run it
on a background thread with a hard timeout. A generous timeout for the first
call and a short one afterwards works well.

**Never probe uninvited.** That same first call is how a root prompt appears.
An app that probes at startup shows a root dialog to someone who never asked
for the feature. Gate it behind an explicit opt-in, and detect installation by
checking whether `lunectl` exists on disk — that needs no root and cannot
prompt.

**Coalesce, do not queue.** A brightness gesture can emit updates faster than a
process can spawn. Keep at most one call in flight and remember only the newest
request; the intermediate states of a drag are not worth a process each.

If you are replacing an overlay dimmer, the conversion that keeps brightness
looking the same is worth getting right. A matte at alpha `a` transmits
`1 - a`. Extra Dim at strength `q` transmits `1 - 0.9556q`. Equal transmitted
light means:

```
q = a / 0.9556
```

so a user switching to the root path sees the brightness the overlay was
already tuned for — produced by emitting less light rather than by laying black
over the screen.

## Quiet Field

`quietctl` mirrors `lunectl`: same exit-code convention, same `key=value`
files, same rule that human-readable `status` output is not part of the
contract.

### Capabilities

From the same `/data/adb/lune/caps`:

| Key | Values | Meaning |
|---|---|---|
| `quiet` | `yes` / `no` | any lever is available |
| `quiet_levers` | space-separated | which of `wake screen fullscreen vibrate notify` this Android has |
| `quiet_notification` | `yes` / `no` | `cmd notification` is reachable, so quiet hours and the watcher work |

Read `quiet_levers` before offering a lever in a UI. `screen` and `fullscreen`
are Android 14+, and the module probes rather than inferring from the SDK
number, so this is the honest answer even on a backporting ROM.

### State

| File | Format | Holds |
|---|---|---|
| `/data/adb/lune/quiet.apps` | `pkg:lever,lever` per line | which apps are quieted |
| `/data/adb/lune/quiet.allow` | one package per line | may break through Do Not Disturb |
| `/data/adb/lune/quiet.conf` | `key=value` | `window`, `dnd`, `watch`, `watch_interval` |
| `/data/adb/lune/quiet.state` | `key=value` | `mode` (`on`/`off`), `since` |
| `/data/adb/lune/quiet.stats` | `YYYY-MM-DD.key=n` | `entered`, `stripped` |

`window` is `HHMM-HHMM` or empty. It may cross midnight — `2100-0800` means
tonight through tomorrow morning, so do not compare it with a naive
`start <= now < end`.

### Commands

```
quietctl add <pkg> [levers]    csv; defaults to wake,screen,fullscreen
quietctl remove <pkg>
quietctl window <HHMM-HHMM|off>
quietctl on | off              enter or leave quiet mode now
quietctl allow <pkg> | disallow <pkg>
quietctl watch <on|off>
quietctl pattern add|remove|list [regex]
quietctl probe
quietctl reset
```

`add` fails on an unknown lever name or an uninstalled package rather than
silently doing nothing — a typo in a lever is otherwise indistinguishable from
a feature that does not work. Levers that exist but are unsupported on this
Android version are dropped with a note, not an error.

### Two things to get right in a UI

**Do not offer `notify` casually.** It blocks an app's notifications outright.
It is in the CLI because someone will want it, but it should take more than one
tap to reach.

**Say what the watcher costs.** It polls, so a matching notification is briefly
visible before it is snoozed, and polling uses battery. A UI that presents it as
free is lying about the only part of the module that is not.

## Falling back without root

An app should keep working when Lune is absent. Without root, the same two
mechanisms are still reachable, just at stock limits, via
`Settings.Secure.NIGHT_DISPLAY_COLOR_TEMPERATURE` and
`REDUCE_BRIGHT_COLORS_LEVEL` — both need `WRITE_SECURE_SETTINGS`, which can be
granted over ADB. Lune widens the range; it is not what makes the mechanism
work.
