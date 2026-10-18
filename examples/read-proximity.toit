// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Reads the proximity engine and shows the value as a bar.

A higher value means a closer object.  The reading is 8-bit.  Offsets,
  gain, LED current and pulse settings change the range; see the setters used
  below.
*/

import i2c
import apds9960 show *

// Please set these correctly for the device in use:
SDA-PIN ::= 21
SCL-PIN ::= 20
FREQUENCY ::= 400_000

main:
  bus := i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  driver.power-on
  driver.set-proximity-defaults
  // Different values for a shorter or longer range:
  driver.set-proximity-gain Apds9960.GAIN-4X
  driver.set-led-drive Apds9960.LED-DRIVE-100MA
  driver.set-led-boost Apds9960.LED-BOOST-100
  driver.enable-proximity

  print "Move a hand towards the sensor."
  100.repeat:
    while not driver.proximity-valid: sleep --ms=5
    value := driver.read-proximity
    print "$(%3d value) $("#" * (value / 4))"
    sleep --ms=100

  driver.disable-proximity
  driver.power-off
  bus.close
