// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import serial.device as serial
import serial.registers as regs

/**
A register-level stand-in for an APDS-9960, for tests that run without hardware.

It is a 256 byte memory with the power-on values from the datasheet and four
  behaviours of the real chip:
  - Reads of the gesture level register report the number of datasets in $fifo.
  - A four byte read of the FIFO registers pops one dataset from $fifo.
  - Single byte writes (the "address only" commands) are recorded in $commands.
  - Writing the FIFO clear bit of GCONF4 empties $fifo, and the bit reads back 0.
  When $auto-exit is true, the gesture mode bit drops the first time the FIFO
  level is read as 0, which imitates the engine leaving gesture mode.
*/
class MockApds9960 implements serial.Device:
  memory/ByteArray := ByteArray 256
  /** The datasets waiting in the FIFO, each a 4 byte byte array. */
  fifo/List := []
  /** The register addresses sent as address-only writes. */
  commands/List := []
  auto-exit/bool := true
  registers_/MockRegisters? := null

  constructor --id/int=0xAB:
    memory[0x81] = 0xFF
    memory[0x83] = 0xFF
    memory[0x8D] = 0x40
    memory[0x8E] = 0x40
    memory[0x90] = 0x01
    memory[0x92] = id
    memory[0x93] = 0x04
    memory[0xA6] = 0x40
    registers_ = MockRegisters this

  registers -> regs.Registers:
    return registers_

  read amount/int -> ByteArray:
    throw "UNSUPPORTED"

  write bytes/ByteArray -> none:
    if bytes.size != 1: throw "UNSUPPORTED"
    commands.add bytes[0]

  read-registers_ register/int count/int -> ByteArray:
    if register == 0xAE:
      level := fifo.size
      if level == 0 and auto-exit: memory[0xAB] = memory[0xAB] & ~0x01
      return #[level]
    if register == 0xFC and count == 4:
      if fifo.is-empty: return ByteArray 4
      return remove-first_ fifo
    result := ByteArray count
    count.repeat: result[it] = memory[register + it]
    return result

  write-registers_ register/int data/ByteArray -> none:
    data.size.repeat: memory[register + it] = data[it]
    if register == 0xAB and (data[0] & 0b100) != 0:
      fifo = []
      memory[0xAB] = memory[0xAB] & ~0b100

/** Pops from the front of a list. */
remove-first_ list/List -> any:
  result := list[0]
  list.remove --at=0
  return result

class MockRegisters extends regs.Registers:
  mock_/MockApds9960

  constructor .mock_:
    super

  read-bytes register/int count/int -> ByteArray:
    return mock_.read-registers_ register count

  write-bytes register/int data/ByteArray -> none:
    mock_.write-registers_ register data
