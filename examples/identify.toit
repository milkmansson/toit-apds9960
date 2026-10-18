// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Finds an APDS-9960 on the I2C bus, checks its ID and switches it on and off.

This is the first example to run when wiring up a new module.  It touches no
  sensing engine.  Set the pins below for the board in use and run with Jaguar:
```
jag run -d <device> examples/identify.toit
```
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

  if not bus.scan.contains Apds9960.I2C-ADDRESS:
    print "No device found at 0x$(%02x Apds9960.I2C-ADDRESS)."
    bus.close
    return

  // The constructor throws UNEXPECTED_DEVICE_ID when the ID register is wrong.
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)
  print "ID register: 0x$(%02x driver.device-id) (expected 0x$(%02x Apds9960.ID-VALUE))"

  driver.power-on
  print "Powered on: $driver.powered-on"
  driver.power-off
  print "Powered on: $driver.powered-on"
  bus.close
