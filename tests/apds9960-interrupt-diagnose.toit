// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Prints the state of the proximity and light interrupts, to find out why an
  interrupt based program does not react.  Needs real hardware.

No callbacks and no tasks are used.  Three phases follow each other, each 8
  seconds long, with different LED settings for the proximity engine.  In every
  phase, cover the sensor for a moment, then hold a hand about 2 to 5 cm above
  it, then take it away.  Every 250 ms one line is printed:
```
INT=1 en=0b00010111 st=0b00000111 prox=  4 clear=  812 ()
```
- `INT` is the level of the ESP32 pin that the module's INT pin is wired to.
  1 is idle, 0 means the chip is asserting the interrupt.
- `en` is the ENABLE register.  It should stay at the value printed in the
  phase header.  A change means the chip was reset or switched off.
- `st` is the status register.  Bit 5 is the proximity interrupt (P), bit 4 the
  light interrupt (A), bit 1 and bit 0 say that fresh proximity and light data
  have arrived since the last read.  Bit 2 is set at all times on the tested
  module.
- `prox` and `clear` are the current readings.
- The marker in brackets names the flags that are set: P and A for the
  interrupts, s and S for proximity and clear channel saturation.

Things to look for:
- Values that stay exactly the same while both data bits (bit 1 and bit 0 of
  `st`) are 0 mean that the engines are not running.
- `prox` above the proximity threshold for several lines without a P flag means
  the proximity interrupt does not trigger.
- A flag with `INT` staying 1 means the INT wire does not reach $INT-PIN.

The interrupts are cleared after each line in which `INT` was 0 or a flag was
  set, so repeated events show up as repeated lines.
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

/** Seconds per phase. */
PHASE-SECONDS ::= 8

main:
  bus := i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=I2C-FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)
  int-pin := gpio.Pin INT-PIN --input --pull-up

  print "Thresholds: proximity high $PROXIMITY-HIGH, light low $LIGHT-LOW, light high $LIGHT-HIGH."

  run-phase driver int-pin "1: as in examples/interrupts.toit (gain 4x, LED 100 mA)" 2:
    driver.set-proximity-gain Apds9960.GAIN-4X
    driver.set-led-drive Apds9960.LED-DRIVE-100MA
  run-phase driver int-pin "2: gentler LED (gain 1x, LED 12.5 mA)" 2:
    driver.set-proximity-gain Apds9960.GAIN-1X
    driver.set-led-drive Apds9960.LED-DRIVE-12-5MA
  run-phase driver int-pin "3: as 1, but persistence 1 (any value outside)" 1:
    driver.set-proximity-gain Apds9960.GAIN-4X
    driver.set-led-drive Apds9960.LED-DRIVE-100MA

  driver.power-off
  bus.close
  print "Done."

/**
Runs one phase.

The $configure block sets the phase specific settings, and $persistence is used
  for both interrupts.
*/
run-phase driver/Apds9960 int-pin/gpio.Pin title/string persistence/int [configure]:
  // Start from a known state.
  driver.reset-registers
  driver.power-on
  driver.set-color-defaults
  driver.set-proximity-defaults
  configure.call
  driver.set-proximity-thresholds --low=0 --high=PROXIMITY-HIGH
  driver.set-proximity-persistence persistence
  driver.set-als-thresholds --low=LIGHT-LOW --high=LIGHT-HIGH
  driver.set-als-persistence persistence
  driver.clear-all-interrupts
  driver.enable-proximity
  driver.enable-als
  driver.enable-proximity-interrupt
  driver.enable-als-interrupt
  enable := driver.read-register 0x80

  print ""
  print "Phase $title"
  print "  ENABLE=0b$(%08b enable), proximity gain $driver.proximity-gain, LED drive $driver.led-drive, pulses register 0x$(%02x driver.read-register 0x8E)"
  print "  Cover the sensor, then bring a hand close, then take it away."

  (PHASE-SECONDS * 4).repeat:
    sleep --ms=250
    status := driver.status
    prox := driver.read-proximity
    color := driver.read-color
    level := int-pin.get
    flags := ""
    if (status & Apds9960.STATUS-PINT) != 0: flags += "P"
    if (status & Apds9960.STATUS-AINT) != 0: flags += "A"
    if (status & Apds9960.STATUS-PGSAT) != 0: flags += "s"
    if (status & Apds9960.STATUS-CPSAT) != 0: flags += "S"
    print "INT=$level en=0b$(%08b driver.read-register 0x80) st=0b$(%08b status) prox=$(%3d prox) clear=$(%5d color.clear) ($flags)"
    if level == 0 or flags != "": driver.clear-all-interrupts
