// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import apds9960 show *
import apds9960.events show *

/**
Uses the proximity and light threshold interrupts.

The sensor compares its readings with thresholds and raises the INT pin when a
  reading stays outside them for the number of cycles set by the persistence.
  The $Apds9960Events class then calls the lambdas and releases the pin again.
  Wire the module's INT pin to $INTERRUPT-PIN.

Here the proximity callback runs when an object comes closer than a value of
  $PROXIMITY-HIGH, and the light callback when the clear channel goes outside
  the range $LIGHT-LOW to $LIGHT-HIGH.
*/

// Set these correctly for the device in use:
SDA-PIN ::= 21
SCL-PIN ::= 20
FREQUENCY ::= 400_000
INTERRUPT-PIN ::= 7

PROXIMITY-HIGH ::= 100
LIGHT-LOW ::= 200
LIGHT-HIGH ::= 3000

main:
  bus := i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  driver.power-on
  driver.set-color-defaults
  driver.set-proximity-defaults
  driver.set-proximity-thresholds --low=0 --high=PROXIMITY-HIGH
  driver.set-proximity-persistence 2  // Two consecutive values outside.
  driver.set-als-thresholds --low=LIGHT-LOW --high=LIGHT-HIGH
  driver.set-als-persistence 2
  driver.enable-proximity
  driver.enable-als

  events := Apds9960Events driver
      --intrpt-pin=(gpio.Pin INTERRUPT-PIN --input --pull-up)
  events.on-proximity --callback=:: | value/int |
    print "Object close, proximity $value"
  events.on-light --callback=:: | color/ColorData |
    print "Light changed: $color"
  events.start

  print "Cover the sensor or bring a hand close."
  while true: sleep --ms=1000
