// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Self-checking tests for an APDS-9960 module wired to an ESP32.  Needs real
  hardware.

Wire SDA, SCL, power and ground, edit the pin numbers below if they differ, and
  run with Jaguar:
```
jag run -d <device> tests/apds9960-hardware-test.toit
```
To test the INT pin as well, wire it to the pin named by $INT-PIN.  Without the
  wire, set $INT-PIN to null.

Every check prints PASS, FAIL, WARN or SKIP.  A FAIL means the driver, the wiring
  or the chip is wrong.  A WARN means a value is odd, or that the expected
  behaviour comes from an unverified reading of the datasheet, and the result
  is information more than a verdict.

Set $GESTURE-TEST to true for a hands-on check.  It asks for a swipe in each
  direction, prints the raw datasets, and suggests the rotation for
  $GestureDecoder when the directions come out turned.
*/

import gpio
import i2c
import apds9960 show *

SDA-PIN ::= 21
SCL-PIN ::= 20
I2C-FREQUENCY ::= 400_000

/** The ESP32 pin that the module's INT pin is wired to, or null if it is not wired. */
INT-PIN/int? ::= 7

/** Set to true to run the hands-on gesture check. */
GESTURE-TEST ::= false

passed := 0
failed := 0
warned := 0

pass name/string:
  passed++
  print "PASS  $name"

fail name/string detail/string:
  failed++
  print "FAIL  $name: $detail"

warn name/string detail/string:
  warned++
  print "WARN  $name: $detail"

check name/string condition/bool detail/string="":
  if condition: pass name
  else: fail name detail

main:
  bus := i2c.Bus
      --sda=SDA-PIN
      --scl=SCL-PIN
      --frequency=I2C-FREQUENCY
  if not bus.scan.contains Apds9960.I2C-ADDRESS:
    print "FAIL  no device at 0x$(%02x Apds9960.I2C-ADDRESS)"
    bus.close
    return
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  test-id driver
  test-round-trips driver
  test-color driver
  test-proximity driver
  if INT-PIN: test-interrupt driver (gpio.Pin INT-PIN --input --pull-up)
  else: print "SKIP  interrupt (no INT pin configured)"
  if GESTURE-TEST: test-gestures driver
  else: print "SKIP  gestures (GESTURE-TEST is false)"

  driver.power-off
  bus.close
  print "Done: $passed passed, $failed failed, $warned warnings."

test-id driver/Apds9960:
  id := driver.device-id
  if id == Apds9960.ID-VALUE: pass "ID register"
  else if Apds9960.ALTERNATE-IDS.contains id: warn "ID register" "0x$(%02x id) is not the datasheet value 0x$(%02x Apds9960.ID-VALUE), run the remaining checks to see whether the registers behave normally"
  else: fail "ID register" "got 0x$(%02x id)"
  driver.power-on
  check "power on" driver.powered-on
  driver.power-off
  check "power off" (not driver.powered-on)
  driver.power-on

/** Writes values and reads them back, which tests addressing and field positions. */
test-round-trips driver/Apds9960:
  driver.set-integration-cycles 37
  check "integration cycles" driver.integration-cycles == 37
  driver.set-wait-cycles 10
  check "wait cycles" driver.wait-cycles == 10
  driver.enable-wait-long
  check "wait long" driver.wait-long-enabled
  driver.disable-wait-long
  driver.set-als-gain Apds9960.ALS-GAIN-16X
  driver.set-proximity-gain Apds9960.GAIN-8X
  driver.set-led-drive Apds9960.LED-DRIVE-25MA
  check "gains and drive" (driver.als-gain == Apds9960.ALS-GAIN-16X and driver.proximity-gain == Apds9960.GAIN-8X and driver.led-drive == Apds9960.LED-DRIVE-25MA)
  driver.set-als-thresholds --low=0x1234 --high=0xABCD
  check "ALS thresholds" (driver.als-low-threshold == 0x1234 and driver.als-high-threshold == 0xABCD)
  driver.set-proximity-thresholds --low=12 --high=200
  check "proximity thresholds" (driver.proximity-low-threshold == 12 and driver.proximity-high-threshold == 200)
  driver.set-proximity-offsets --up-right=-20 --down-left=30
  check "proximity offsets" (driver.proximity-offset-up-right == -20 and driver.proximity-offset-down-left == 30)
  driver.set-proximity-offsets --up-right=0 --down-left=0
  driver.set-gesture-offsets --up=1 --down=-2 --left=3 --right=-4
  check "gesture offsets" driver.gesture-offsets == [1, -2, 3, -4]
  driver.set-gesture-offsets --up=0 --down=0 --left=0 --right=0
  driver.set-gesture-defaults
  check "gesture defaults" (driver.gesture-entry-threshold == 40 and driver.gesture-exit-threshold == 30 and driver.gesture-fifo-threshold == 4)
  driver.set-color-defaults
  driver.set-proximity-defaults

test-color driver/Apds9960:
  driver.enable-als
  deadline := Time.monotonic-us + 1_000_000
  while not driver.color-valid and Time.monotonic-us < deadline: sleep --ms=10
  check "colour data becomes valid" driver.color-valid
  color := driver.read-color
  print "      $color  (maximum count $driver.als-max-count)"
  if color.clear == 0: warn "colour" "clear channel is 0, is the sensor covered or the room dark?"
  else if color.clear >= driver.als-max-count: warn "colour" "clear channel is saturated"
  else: pass "colour reading"
  driver.disable-als

test-proximity driver/Apds9960:
  driver.enable-proximity
  deadline := Time.monotonic-us + 1_000_000
  while not driver.proximity-valid and Time.monotonic-us < deadline: sleep --ms=5
  check "proximity data becomes valid" driver.proximity-valid
  value := driver.read-proximity
  print "      proximity $value"
  if value >= 250: warn "proximity" "reading is near saturation with nothing in front, check for a cover or reflections"
  else: pass "proximity reading"
  driver.disable-proximity

/**
Tests the INT pin.

The expectation that a forced interrupt pulls the pin low comes from the
  register name IFORCE ("Forces an interrupt") alone.  Whether the interrupt
  enable bits are also needed is not stated, so both are set and a failure
  here is reported as a warning.
*/
test-interrupt driver/Apds9960 pin/gpio.Pin:
  driver.clear-all-interrupts
  sleep --ms=10
  check "INT idle high" pin.get == 1 "pin is low with no interrupt pending"
  driver.enable-proximity
  driver.enable-proximity-interrupt
  driver.enable-als
  driver.enable-als-interrupt
  driver.force-interrupt
  sleep --ms=20
  if pin.get == 0: pass "forced interrupt pulls INT low"
  else: warn "forced interrupt" "INT stayed high"
  driver.clear-all-interrupts
  sleep --ms=10
  check "clear releases INT" pin.get == 1 "pin still low after clear-all-interrupts, status 0b$(%08b driver.status)"
  driver.disable-proximity-interrupt
  driver.disable-als-interrupt
  driver.disable-proximity
  driver.disable-als

/**
Asks for a swipe in each direction and compares the decoded directions.

The sequence of expected directions is up, right, down, left, with the
  direction understood as the direction in which the hand moves, seen from the
  sensor's own orientation.  If every result is turned by the same amount, the
  rotation to give $GestureDecoder is printed.
*/
test-gestures driver/Apds9960:
  driver.set-proximity-defaults
  driver.set-gesture-defaults
  driver.enable-proximity
  driver.enable-gesture
  names := ["up", "right", "down", "left"]
  offsets := []
  4.repeat: | i |
    print "      Swipe a hand $(names[i]) over the sensor within 10 s ..."
    data := driver.collect-gesture-data --timeout=(Duration --s=10)
    if data == null:
      warn "gesture $(names[i])" "no gesture detected, try a slower swipe closer to the sensor"
      continue.repeat
    print "      $(data.size / 4) datasets (up, down, left, right):"
    (data.size / 4).repeat: | j |
      print "        $data[j * 4] $data[j * 4 + 1] $data[j * 4 + 2] $data[j * 4 + 3]"
    result := (GestureDecoder).decode data
    if result == null:
      warn "gesture $(names[i])" "not recognised, the threshold or sensitivity may need tuning"
    else:
      offsets.add ((result - i) % 4 + 4) % 4
      print "      decoded: $(Gesture.name-of result)"
    if driver.gesture-fifo-overflow: warn "gesture $(names[i])" "the FIFO overflowed"
    sleep --ms=1000
  if offsets.size == 4 and (offsets.every: it == offsets[0]):
    if offsets[0] == 0: pass "gesture directions"
    else: warn "gesture directions" "all turned by the same amount, try GestureDecoder --rotation=$((4 - offsets[0]) * 90 % 360)"
  else if offsets.size > 0:
    warn "gesture directions" "inconsistent results, offsets in quarter turns: $offsets"
