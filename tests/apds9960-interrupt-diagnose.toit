// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Prints the state of the proximity and light interrupts, to find out why an
  interrupt based program does not react.  Needs real hardware.

It uses the same settings as examples/interrupts.toit but no callbacks and no
  tasks.  Every 200 ms it prints one line:
```
INT=1 status=0b00000011 prox=  4 clear= 812 ( )
```
- `INT` is the level of the ESP32 pin that the module's INT pin is wired to.
  1 is idle, 0 means the chip is asserting the interrupt.
- `status` is the chip's status register.  Bit 5 (PINT) is the proximity
  interrupt and bit 4 (AINT) the light interrupt.
- `prox` and `clear` are the current readings.
- The marker in brackets names the interrupt flags that are set, P and A.

Cover the sensor, then bring a hand close, and watch which values change.
  What the combinations mean:
- `prox` or `clear` never change: the engine is not running, or the sensor is
  not seeing anything.
- `prox` rises above the high threshold and `clear` falls below the low one,
  but the flags stay clear: the interrupt configuration is not taking effect.
- A flag shows up in the marker but `INT` stays 1: the INT wire is missing, or
  it goes to another pin than $INT-PIN.
- `INT` goes to 0 here but the callback example prints nothing: the problem is
  in the event handling and not in the chip or the wiring.

The interrupts are cleared after each line in which `INT` was 0, so repeated
  events show up as repeated lines.
*/

import gpio
import i2c
import apds9960 show *

SDA-PIN ::= 21
SCL-PIN ::= 20
I2C-FREQUENCY ::= 400_000
INT-PIN ::= 7

PROXIMITY-HIGH ::= 100
LIGHT-LOW ::= 200
LIGHT-HIGH ::= 3000

main:
  bus := i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=I2C-FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)
  int-pin := gpio.Pin INT-PIN --input --pull-up

  driver.power-on
  driver.set-color-defaults
  driver.set-proximity-defaults
  driver.set-proximity-thresholds --low=0 --high=PROXIMITY-HIGH
  driver.set-proximity-persistence 2
  driver.set-als-thresholds --low=LIGHT-LOW --high=LIGHT-HIGH
  driver.set-als-persistence 2
  driver.enable-proximity
  driver.enable-als
  driver.enable-proximity-interrupt
  driver.enable-als-interrupt
  driver.clear-all-interrupts

  // Read back what was configured, to show that it landed.
  print "powered=$driver.powered-on als=$driver.als-enabled proximity=$driver.proximity-enabled"
  print "interrupts: proximity=$driver.proximity-interrupt-enabled als=$driver.als-interrupt-enabled"
  print "proximity thresholds: low=$driver.proximity-low-threshold high=$driver.proximity-high-threshold persistence=$driver.proximity-persistence"
  print "light thresholds: low=$driver.als-low-threshold high=$driver.als-high-threshold persistence=$driver.als-persistence"
  print "integration: $driver.integration-cycles cycles, $(%.1f driver.integration-time-ms) ms, gain value $driver.als-gain"
  print "Cover the sensor, then bring a hand close."

  200.repeat:
    sleep --ms=200
    status := driver.status
    prox := driver.read-proximity
    color := driver.read-color
    level := int-pin.get
    flags := ""
    if (status & Apds9960.STATUS-PINT) != 0: flags += "P"
    if (status & Apds9960.STATUS-AINT) != 0: flags += "A"
    if (status & Apds9960.STATUS-PGSAT) != 0: flags += "s"
    if (status & Apds9960.STATUS-CPSAT) != 0: flags += "S"
    print "INT=$level status=0b$(%08b status) prox=$(%3d prox) clear=$(%5d color.clear) ($flags)"
    if level == 0 or flags != "": driver.clear-all-interrupts

  driver.disable-proximity-interrupt
  driver.disable-als-interrupt
  driver.disable-proximity
  driver.disable-als
  driver.power-off
  bus.close
