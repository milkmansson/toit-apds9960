// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Detects hand swipes by polling, with no INT pin.

The call to $Apds9960.read-gesture waits until the gesture engine starts,
  empties the FIFO while the hand moves, and returns the decoded direction.
  Swipe a hand across the sensor, 5 to 10 cm above it, at moderate speed.

The decoder settings are starting values.  If swipes come out rotated or
  mirrored, set the rotation of the $GestureDecoder.  The hardware test in the
  tests folder prints raw data that helps to find the right value.
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

  // The gesture engine needs the proximity engine.  Configure first, enable last.
  driver.power-on
  driver.set-proximity-defaults
  driver.set-gesture-defaults
  driver.enable-proximity
  driver.enable-gesture

  decoder := GestureDecoder --rotation=0
  print "Swipe a hand over the sensor."
  while true:
    gesture := driver.read-gesture --timeout=(Duration --s=10) --decoder=decoder
    if gesture: print "Gesture: $(Gesture.name-of gesture)"
