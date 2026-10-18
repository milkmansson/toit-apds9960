// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Reads the clear, red, green and blue channels.

Prints one reading per integration period, together with the largest count the
  channels can reach at the chosen integration time.  A channel at that count is
  saturated, and a lower gain or a shorter integration time is needed.
*/

import gpio
import i2c
import apds9960 show *

// Please set these correctly for the device in use:
SDA-PIN ::= 8
SCL-PIN ::= 9
FREQUENCY ::= 400_000

main:
  bus := i2c.Bus
      --sda=(gpio.Pin SDA-PIN)
      --scl=(gpio.Pin SCL-PIN)
      --frequency=FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  driver.power-on
  driver.set-color-defaults
  // Both can be changed from the starting values:
  driver.set-integration-time --ms=103
  driver.set-als-gain Apds9960.ALS-GAIN-4X
  driver.enable-als

  print "Integration time: $(%.1f driver.integration-time-ms) ms, maximum count: $driver.als-max-count"
  10.repeat:
    // The first conversion needs a full integration period.
    while not driver.color-valid: sleep --ms=10
    print driver.read-color
    sleep --ms=500

  driver.disable-als
  driver.power-off
  bus.close
