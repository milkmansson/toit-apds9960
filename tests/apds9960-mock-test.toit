// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Tests the register logic of the APDS-9960 driver against a mock chip.

Needs no hardware.  Run with `toit run tests/apds9960-mock-test.toit` from the
  package directory.  Expected values come from the datasheet, and the places
  where that is the case are named in the comments.
*/

import expect show *
import log
import apds9960 show *
import .mock-apds9960

new-driver mock/MockApds9960 -> Apds9960:
  return Apds9960 mock --logger=(log.Logger log.FATAL-LEVEL log.DefaultTarget)

main:
  test-id
  test-enable-bits
  test-timing
  test-fields
  test-offsets
  test-thresholds
  test-commands
  test-color
  test-gesture-config
  test-gesture-fifo
  test-gesture-collect
  test-decoder
  print "All mock tests passed."

test-id:
  mock := MockApds9960
  driver := new-driver mock
  expect-equals 0xAB driver.device-id
  bad := MockApds9960 --id=0x12
  expect-throw "UNEXPECTED_DEVICE_ID": new-driver bad
  // An alternate ID is accepted with a warning.
  new-driver (MockApds9960 --id=0x9E)
  // Skipping the check works.
  Apds9960 bad --no-verify-id --logger=(log.Logger log.FATAL-LEVEL log.DefaultTarget)

test-enable-bits:
  mock := MockApds9960
  driver := new-driver mock
  expect-not driver.gesture-enabled
  driver.enable-gesture
  expect driver.gesture-enabled
  expect-equals 0b01000000 mock.memory[0x80]
  // The getters read the ENABLE register and not CONFIG1.
  expect-equals 0x40 mock.memory[0x8D]
  driver.power-on
  driver.enable-als
  driver.enable-proximity
  driver.enable-wait-timer
  driver.enable-proximity-interrupt
  driver.enable-als-interrupt
  expect-equals 0b01111111 mock.memory[0x80]
  expect driver.powered-on
  expect driver.als-enabled
  expect driver.proximity-enabled
  expect driver.wait-timer-enabled
  expect driver.proximity-interrupt-enabled
  expect driver.als-interrupt-enabled
  driver.disable-gesture
  driver.disable-wait-timer
  expect-equals 0b00110111 mock.memory[0x80]
  expect-not driver.gesture-enabled
  expect-not driver.wait-timer-enabled
  driver.power-off
  expect-not driver.powered-on

test-timing:
  mock := MockApds9960
  driver := new-driver mock
  // Datasheet: ATIME 219 is 37 cycles, 103 ms, max count 37889.
  driver.set-integration-cycles 37
  expect-equals 219 mock.memory[0x81]
  expect-equals 37 driver.integration-cycles
  expect-equals 37889 driver.als-max-count
  expect (driver.integration-time-ms - 102.86).abs < 0.01
  // ATIME 0 is 256 cycles, capped at 65535.
  driver.set-integration-cycles 256
  expect-equals 0 mock.memory[0x81]
  expect-equals 65535 driver.als-max-count
  driver.set-integration-time --ms=27.8
  expect-equals 10 driver.integration-cycles
  expect-equals 10241 driver.als-max-count
  expect-throw "OUT_OF_RANGE": driver.set-integration-cycles 0
  expect-throw "OUT_OF_RANGE": driver.set-integration-cycles 257
  // Datasheet: WTIME 246 is 10 cycles, 27.8 ms.  WLONG multiplies by 12.
  driver.set-wait-cycles 10
  expect-equals 246 mock.memory[0x83]
  expect (driver.wait-time-ms - 27.8).abs < 0.01
  driver.enable-wait-long
  expect driver.wait-long-enabled
  expect-equals 0x42 mock.memory[0x8D]  // The reserved bit 6 stays set.
  expect (driver.wait-time-ms - 333.6).abs < 0.01
  driver.disable-wait-long
  expect-equals 0x40 mock.memory[0x8D]

test-fields:
  mock := MockApds9960
  driver := new-driver mock
  driver.set-als-gain Apds9960.ALS-GAIN-64X
  driver.set-proximity-gain Apds9960.GAIN-4X
  driver.set-led-drive Apds9960.LED-DRIVE-50MA
  expect-equals 0b01001011 mock.memory[0x8F]
  expect-equals Apds9960.ALS-GAIN-64X driver.als-gain
  expect-equals Apds9960.GAIN-4X driver.proximity-gain
  expect-equals Apds9960.LED-DRIVE-50MA driver.led-drive
  driver.set-als-gain Apds9960.ALS-GAIN-1X
  expect-equals 0b01001000 mock.memory[0x8F]
  expect-throw "OUT_OF_RANGE": driver.set-als-gain 4
  expect-throw "OUT_OF_RANGE": driver.set-als-gain -1

  driver.set-led-boost Apds9960.LED-BOOST-300
  expect-equals 0b00110001 mock.memory[0x90]  // Reserved bit 0 stays set.
  expect-equals Apds9960.LED-BOOST-300 driver.led-boost
  driver.enable-proximity-saturation-interrupt
  driver.enable-als-saturation-interrupt
  expect-equals 0b11110001 mock.memory[0x90]

  driver.set-proximity-pulses --count=8 --length=Apds9960.PULSE-LENGTH-16US
  expect-equals 0x87 mock.memory[0x8E]
  driver.set-proximity-pulses --count=64 --length=Apds9960.PULSE-LENGTH-4US
  expect-equals 0x3F mock.memory[0x8E]
  expect-throw "OUT_OF_RANGE": driver.set-proximity-pulses --count=0 --length=0
  expect-throw "OUT_OF_RANGE": driver.set-proximity-pulses --count=65 --length=0

  driver.set-proximity-photodiodes --up=false --right=false
  expect-equals 0b1001 mock.memory[0x9F]
  driver.enable-proximity-gain-compensation
  driver.enable-sleep-after-interrupt
  expect-equals 0b00111001 mock.memory[0x9F]

  driver.set-proximity-persistence 3
  driver.set-als-persistence 10
  expect-equals 0x3A mock.memory[0x8C]
  expect-equals 3 driver.proximity-persistence
  expect-equals 10 driver.als-persistence

test-offsets:
  mock := MockApds9960
  driver := new-driver mock
  // Sign and magnitude, per the datasheet: 01111111 is 127 and 11111111 is -127.
  driver.set-proximity-offsets --up-right=127 --down-left=-127
  expect-equals 0x7F mock.memory[0x9D]
  expect-equals 0xFF mock.memory[0x9E]
  expect-equals 127 driver.proximity-offset-up-right
  expect-equals -127 driver.proximity-offset-down-left
  driver.set-proximity-offsets --up-right=-1 --down-left=0
  expect-equals 0x81 mock.memory[0x9D]
  expect-equals 0x00 mock.memory[0x9E]
  driver.set-gesture-offsets --up=5 --down=-5 --left=0 --right=-100
  expect-equals 0x05 mock.memory[0xA4]
  expect-equals 0x85 mock.memory[0xA5]
  expect-equals 0x00 mock.memory[0xA7]
  expect-equals (0x80 | 100) mock.memory[0xA9]
  expect-equals [5, -5, 0, -100] driver.gesture-offsets
  expect-throw "OUT_OF_RANGE": driver.set-gesture-offsets --up=128 --down=0 --left=0 --right=0

test-thresholds:
  mock := MockApds9960
  driver := new-driver mock
  driver.set-als-thresholds --low=0x1234 --high=0xABCD
  expect-equals 0x34 mock.memory[0x84]
  expect-equals 0x12 mock.memory[0x85]
  expect-equals 0xCD mock.memory[0x86]
  expect-equals 0xAB mock.memory[0x87]
  expect-equals 0x1234 driver.als-low-threshold
  expect-equals 0xABCD driver.als-high-threshold
  driver.set-proximity-thresholds --low=10 --high=200
  expect-equals 10 mock.memory[0x89]
  expect-equals 200 mock.memory[0x8B]
  expect-equals 10 driver.proximity-low-threshold
  expect-equals 200 driver.proximity-high-threshold
  expect-throw "OUT_OF_RANGE": driver.set-proximity-thresholds --low=0 --high=256
  expect-throw "OUT_OF_RANGE": driver.set-als-thresholds --low=-1 --high=0

test-commands:
  mock := MockApds9960
  driver := new-driver mock
  driver.clear-proximity-interrupt
  driver.clear-als-interrupt
  driver.clear-all-interrupts
  driver.force-interrupt
  expect-equals [0xE5, 0xE6, 0xE7, 0xE4] mock.commands
  mock.memory[0x93] = Apds9960.STATUS-PINT | Apds9960.STATUS-AVALID
  expect driver.proximity-interrupt-pending
  expect-not driver.als-interrupt-pending
  expect-not driver.gesture-interrupt-pending
  expect driver.color-valid
  expect-not driver.proximity-valid

test-color:
  mock := MockApds9960
  driver := new-driver mock
  // Clear 0x0201, red 0x0403, green 0x0605, blue 0xFFFE.
  [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xFE, 0xFF].size.repeat:
    mock.memory[0x94 + it] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xFE, 0xFF][it]
  color := driver.read-color
  expect-equals 0x0201 color.clear
  expect-equals 0x0403 color.red
  expect-equals 0x0605 color.green
  expect-equals 0xFFFE color.blue
  mock.memory[0x9C] = 200
  expect-equals 200 driver.read-proximity

test-gesture-config:
  mock := MockApds9960
  driver := new-driver mock
  driver.set-gesture-fifo-threshold 8
  driver.set-gesture-exit-mask (Apds9960.EXIT-MASK-UP | Apds9960.EXIT-MASK-LEFT)
  driver.set-gesture-exit-persistence 2
  expect-equals 0b10101010 mock.memory[0xA2]
  expect-equals 8 driver.gesture-fifo-threshold
  expect-equals 0b1010 driver.gesture-exit-mask
  expect-equals 2 driver.gesture-exit-persistence
  expect-throw "OUT_OF_RANGE": driver.set-gesture-fifo-threshold 5
  driver.set-gesture-gain Apds9960.GAIN-8X
  driver.set-gesture-led-drive Apds9960.LED-DRIVE-25MA
  driver.set-gesture-wait-time 7
  expect-equals 0b01110111 mock.memory[0xA3]
  driver.set-gesture-dimensions Apds9960.GESTURE-DIMENSIONS-LEFT-RIGHT
  expect-equals 2 mock.memory[0xAA]
  expect-equals 2 driver.gesture-dimensions

  driver.set-gesture-defaults
  expect-equals 40 mock.memory[0xA0]
  expect-equals 30 mock.memory[0xA1]
  expect-equals 0b01000001 mock.memory[0xA2]
  expect-equals 0b01000001 mock.memory[0xA3]
  expect-equals 0xC9 mock.memory[0xA6]  // 32 us, 10 pulses.
  expect-equals 0 mock.memory[0xAA]

  driver.enable-gesture-interrupt
  driver.enter-gesture-mode
  expect driver.gesture-interrupt-enabled
  expect driver.gesture-mode-active
  expect-equals 0b11 mock.memory[0xAB]
  // Clearing the FIFO keeps the interrupt enable and leaves gesture mode.
  mock.fifo = [#[1, 2, 3, 4]]
  driver.clear-gesture-fifo
  expect-equals 0b10 mock.memory[0xAB]
  expect mock.fifo.is-empty
  expect-not driver.gesture-mode-active

test-gesture-fifo:
  mock := MockApds9960
  driver := new-driver mock
  expect-equals 0 driver.gesture-fifo-level
  expect-equals #[] driver.read-gesture-data
  mock.fifo = [#[1, 2, 3, 4], #[5, 6, 7, 8], #[9, 10, 11, 12]]
  expect-equals 3 driver.gesture-fifo-level
  expect-equals #[1, 2, 3, 4, 5, 6, 7, 8] (driver.read-gesture-data --max-datasets=2)
  expect-equals 1 driver.gesture-fifo-level
  expect-equals #[9, 10, 11, 12] driver.read-gesture-data
  expect-equals 0 driver.gesture-fifo-level

test-gesture-collect:
  mock := MockApds9960
  driver := new-driver mock
  // Nothing happens: the call times out.
  expect-null (driver.collect-gesture-data --timeout=(Duration --ms=50))
  // The engine is running and has data: all of it is returned and the call
  // finishes once the engine has exited.
  mock.memory[0xAB] = 0x01
  mock.fifo = List 5: | i | ByteArray 4: i + 1
  data := driver.collect-gesture-data --timeout=(Duration --ms=200)
  expect-equals 20 data.size
  expect-equals 5 data[16]
  expect-not driver.gesture-mode-active
  // Without a running engine but with data in the FIFO, the data is returned.
  mock.fifo = [#[9, 9, 9, 9]]
  expect-equals #[9, 9, 9, 9] (driver.collect-gesture-data --timeout=(Duration --ms=200))

/** Builds four datasets that move from $first to $last, for the decoder tests. */
make-data first/List last/List -> ByteArray:
  mid := List 4: (first[it] + last[it]) / 2
  rows := [first, mid, mid, last]
  result := ByteArray 16
  rows.size.repeat: | i |
    4.repeat: | j |
      result[i * 4 + j] = rows[i][j]
  return result

test-decoder:
  decoder := GestureDecoder
  // Order is up, down, left, right.  Down motion: the down diode sees the
  // reflection first, the up diode last.
  expect-equals Gesture.DOWN (decoder.decode (make-data [30, 120, 80, 80] [120, 30, 80, 80]))
  expect-equals Gesture.UP (decoder.decode (make-data [120, 30, 80, 80] [30, 120, 80, 80]))
  expect-equals Gesture.RIGHT (decoder.decode (make-data [80, 80, 30, 120] [80, 80, 120, 30]))
  expect-equals Gesture.LEFT (decoder.decode (make-data [80, 80, 120, 30] [80, 80, 30, 120]))
  // Both axes move: the larger change wins.
  expect-equals Gesture.DOWN (decoder.decode (make-data [30, 120, 60, 100] [120, 30, 90, 70]))
  // Too small a change, or too few usable datasets.
  expect-null (decoder.decode (make-data [80, 90, 80, 80] [90, 80, 80, 80]))
  expect-null (decoder.decode #[])
  expect-null (decoder.decode #[100, 100, 100, 100])
  expect-null (decoder.decode #[1, 2, 3, 4, 5, 6, 7, 8])
  // Datasets below the threshold at either end are ignored.
  padded := #[0, 0, 0, 0] + (make-data [30, 120, 80, 80] [120, 30, 80, 80]) + #[2, 1, 0, 0]
  expect-equals Gesture.DOWN (decoder.decode padded)
  // A rotated module turns every direction.
  rotated := GestureDecoder --rotation=90
  expect-equals Gesture.RIGHT (rotated.decode (make-data [120, 30, 80, 80] [30, 120, 80, 80]))
  expect-equals Gesture.DOWN ((GestureDecoder --rotation=-90).decode (make-data [80, 80, 120, 30] [80, 80, 30, 120]))
  expect-throw "INVALID_ARGUMENT": GestureDecoder --rotation=45
  expect-equals "up" (Gesture.name-of Gesture.UP)
  expect-equals "none" (Gesture.name-of null)
