# Toit driver for the Broadcom APDS-9960 light, colour, proximity and gesture sensor

Reads ambient light and RGB colour, proximity, and hand gestures from the
APDS-9960 over I2C, with optional interrupt driven callbacks.

| Chip | I2C address | Status |
|---|---|---|
| APDS-9960 *(common breakout modules)* | 0x39 (fixed) | Written from the datasheet. Register logic tested against a mock chip. **Not yet run on real hardware.** |

## Quick start

```toit
import i2c
import apds9960 show *

main:
  bus := i2c.Bus --sda=21 --scl=20 --frequency=400_000
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  driver.power-on
  driver.set-color-defaults
  driver.enable-als
  while not driver.color-valid: sleep --ms=10
  print driver.read-color  // clear=1200 red=400 green=500 blue=300
```

The constructor reads the ID register. The datasheet documents 0xAB. A module
reporting 0x9E was seen working during development, and that value is accepted
with a logged warning (`Apds9960.ALTERNATE-IDS`). Any other value throws
`UNEXPECTED_DEVICE_ID`, and `--no-verify-id` skips the check.

The chip keeps its register values when a program ends, so the constructor then
calls `reset-registers`, which writes the datasheet's power-up values (all engines
and interrupts off, power off). `--no-reset` leaves the chip as found. The reason
is the datasheet's gesture entry rule: "the Gesture engine is entered when its
enable bit, GEN, and the operating mode bit, GMODE, are both set", and GMODE
"becomes set when proximity results, PDATA, is greater or equal to the gesture
proximity entry threshold, GPENTH". Observed on the development module (a
reading, not a datasheet statement): after a gesture example had run, a later
proximity and light program froze, with both data-valid bits 0 and identical
readings, whenever the proximity value reached the old entry threshold. The
cause is estimated to be the gesture engine taking over the cycle. The datasheet
asks that
"Before enabling Gesture, Proximity, or ALS, all of the bits associated with
control of the desired function must be set", so the order is `power-on`, the
setters, then `enable-*`.

## Examples

The library works with Toit SDK 2.0.0-alpha.195 or newer. The examples and tests
pass integer pin numbers to `i2c.Bus`, which needs alpha.196 or newer.

| File | Shows |
|---|---|
| `examples/identify.toit` | Bus scan, ID check, power on and off. Run this first. |
| `examples/read-color.toit` | Clear, red, green and blue channels, integration time and gain. |
| `examples/read-proximity.toit` | Proximity value, gain, LED current. |
| `examples/read-gesture-polling.toit` | Swipe detection without the INT pin. |
| `examples/read-gesture-events.toit` | Swipe detection with the INT pin and a callback. |
| `examples/interrupts.toit` | Proximity and light threshold interrupts with callbacks. |

## The engines

| Engine | Enable | Read | Main settings |
|---|---|---|---|
| Colour and ambient light | `enable-als` | `read-color` | `set-integration-time`, `set-als-gain` |
| Proximity | `enable-proximity` | `read-proximity` | `set-proximity-gain`, `set-led-drive`, `set-led-boost`, `set-proximity-pulses`, `set-proximity-offsets`, `set-proximity-photodiodes` |
| Gesture | `enable-gesture` (and `enable-proximity`) | `read-gesture`, `collect-gesture-data`, `read-gesture-data` | `set-gesture-*` |
| Wait timer | `enable-wait-timer` | | `set-wait-cycles`, `enable-wait-long` |

Settings are set with `set-*` methods and read back with the same name without
the prefix, for example `set-als-gain` and `als-gain`. Enumerated settings use
constants such as `Apds9960.GAIN-4X`, `LED-DRIVE-100MA` and `PULSE-LENGTH-16US`.
Raw register values are used where the datasheet defines a table (persistence,
gesture wait time), and the toitdoc states what the values mean.

Colour channels are 16-bit. The largest count depends on the integration
time, see `als-max-count`. A channel at that count is saturated.

Proximity offsets and gesture offsets are signed values from -127 to 127. The
chip stores them as sign and magnitude, which the driver converts.

## Gestures

The chip does not report a direction. Per the datasheet, "A dataset is defined
as 4-byte directional data corresponding to U-D-L-R. The FIFO can buffer up to
32 datasets before it overflows. If the FIFO overflows (host did not read
quickly enough) then the most recent data will be lost." The driver therefore
offers three levels:

- `read-gesture-data` returns what is in the FIFO right now, four bytes per
  dataset in the order up, down, left, right.
- `collect-gesture-data` waits for the gesture engine to start, empties the FIFO
  while it runs, and returns all datasets of one gesture.
- `read-gesture` does the same and decodes the result with a `GestureDecoder`.

The datasheet says only that "Ideally, gesture detection works by capturing and
comparing the amplitude and phase difference between directional sensor
results", and that the diode opposite to the direction of motion receives the
larger share of the reflection on entry and the smaller on exit. `GestureDecoder`
applies that idea: it compares the normalised up-down and left-right differences
of the first and last usable dataset. This is an estimate and not an algorithm
from the datasheet. The approach is understood to resemble that of common
Arduino libraries (see the references below), but their source was not consulted.

Whether a swipe is reported as the right direction also depends on how the chip
sits on the module. If all four directions come out turned by the same amount,
pass `--rotation` to `GestureDecoder`. Running the hardware test with
`GESTURE-TEST` set to true prints the raw datasets and suggests a value.

The decoder is a plain class that takes bytes, so it can also be used on
recorded data, and `tests/apds9960-mock-test.toit` runs it on synthetic data.

## Interrupts and callbacks

The core `Apds9960` class starts no tasks, and the application decides when to
poll. For interrupt driven use, `import apds9960.events show *` provides
`Apds9960Events`, an optional layer in the same shape as the events class of the
MPR121 driver:

```toit
events := Apds9960Events driver --intrpt-pin=(gpio.Pin 7 --input --pull-up)
events.on-gesture --callback=:: | gesture/int | print (Gesture.name-of gesture)
events.on-proximity --callback=:: | value/int | print "close: $value"
events.on-light --callback=:: | color/ColorData | print color
events.start
```

The INT pin is "open drain (active low)" per the datasheet, so it needs a
pull-up. `start` enables only the interrupts that have a callback. One runner
task waits on the pin and calls the lambdas on that task, so a lambda that
blocks delays the reading of the gesture FIFO. Proximity and light interrupts
stay asserted until cleared, and `Apds9960Events` clears them after each
callback. Applications that handle interrupts themselves use
`clear-proximity-interrupt`, `clear-als-interrupt` and `clear-all-interrupts`,
which send the "special I2C transaction consisting of only two bytes" that the
datasheet describes. Gesture interrupts clear when the FIFO is emptied.

While the runner is active, the application should not use the driver for the
engines that the callbacks serve, since two tasks reading the same device can
interleave.

Without the pin, or with one shared housekeeping task, construct
`Apds9960Events` without `--intrpt-pin`, set the interrupt enables on the driver,
and call `events.service` from the application's loop. It reads the status once
and runs the matching lambdas.

The status register bit that the datasheet calls the gesture interrupt (bit 2)
read 1 at all times on the module used for development, which matches the
datasheet's power-up value of 0x04. Gesture data is therefore detected from the
FIFO level and the gesture mode bit, not from that status bit.


## References

- [APDS-9960 datasheet (Broadcom, AV02-4191EN)](https://docs.broadcom.com/doc/AV02-4191EN). Register layouts, bit positions, timing tables and the quotations above come from this document.
- [SparkFun APDS-9960 Arduino library](https://github.com/sparkfun/SparkFun_APDS-9960_Sensor_Arduino_Library) and [Adafruit APDS9960 library](https://github.com/adafruit/Adafruit_APDS9960). Named only as widely used implementations whose gesture handling is similar in outline. Not consulted for this driver, and no code was copied from them.
- [Toit package documentation](https://docs.toit.io/language/package).

Where behaviour is estimated and not taken from the datasheet, the toitdoc or a
comment in the source says so.

## Issues

If there are any issues, changes, or any other kind of feedback, please
[raise an issue](toit-apds9960/issues). Feedback is welcome and appreciated!

## Disclaimer

- This driver was written from the datasheet, and has not yet been tested on an
  APDS-9960 module.
- All trademarks belong to their respective owners.
- No warranties for this work, express or implied.

## Credits

- [Florian](https://github.com/floitsch) for the tireless help and encouragement.
- The wider Toit developer team (past and present) for a truly excellent product.

## About Toit
> Toit is a high-level, memory-safe language, with container/VM technology built
> specifically for microcontrollers (not a desktop language port). It gives fast
> iteration (live reloads over Wi-Fi in seconds), robust serviceability, and
> performance that’s far closer to C than typical scripting options on the
> ESP32. [[link](https://toitlang.org/)]
- [Review on Soracom](https://soracom.io/blog/internet-of-microcontrollers-made-easy-with-toit-x-soracom/).
- [Review on eeJournal](https://www.eejournal.com/article/its-time-to-get-toit).
- Toit on [Wikipedia](https://en.wikipedia.org/wiki/Toit).
