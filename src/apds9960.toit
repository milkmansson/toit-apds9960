// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.   This file also includes derivative
// work from other authors and sources with permission.  See README.md.

import io
import log
import serial.device as serial
import serial.registers as registers

/**
Toit driver for the Broadcom APDS-9960 digital proximity, ambient light, RGB
  and gesture sensor.

The sensor has four engines: ambient light and colour (ALS), proximity,
  gesture, and a wait timer.  This class exposes each of them as plain methods.
  The class holds no tasks and no state beyond the bus handle, so the
  application decides when to poll.  The `apds9960.events` library holds
  `Apds9960Events`, an optional interrupt driven wrapper that runs callbacks.

The datasheet asks that "Before enabling Gesture, Proximity, or ALS, all of the
  bits associated with control of the desired function must be set."  The
  usual order is therefore $Apds9960.power-on, then the configuration setters,
  then the matching enable method.

# Gestures
The chip does not report a direction.  It places raw samples from its four
  photodiodes (up, down, left, right) in a 32 entry FIFO.  The methods
  $Apds9960.gesture-fifo-level and $Apds9960.read-gesture-data give access to
  those samples, and $GestureDecoder turns them into a direction.  The method
  $Apds9960.read-gesture combines everything for the common case.
*/

/** A reading of the clear, red, green and blue channels. */
class ColorData:
  /** The clear (unfiltered) channel, as a 16-bit value. */
  clear/int
  /** The red channel, as a 16-bit value. */
  red/int
  /** The green channel, as a 16-bit value. */
  green/int
  /** The blue channel, as a 16-bit value. */
  blue/int

  constructor --.clear --.red --.green --.blue:

  stringify -> string:
    return "clear=$clear red=$red green=$green blue=$blue"

/**
Gesture directions reported by $GestureDecoder.

The direction is the direction in which the hand (or other reflecting object)
  moved, as seen from the sensor's own orientation.  Whether that matches the
  orientation of a particular breakout board depends on how the chip is
  mounted.  The $GestureDecoder rotation compensates for that.
*/
class Gesture:
  static UP    ::= 0
  static RIGHT ::= 1
  static DOWN  ::= 2
  static LEFT  ::= 3

  /** Returns a readable name for the given $gesture, or "none" for null. */
  static name-of gesture/int? -> string:
    if gesture == null: return "none"
    if gesture == UP: return "up"
    if gesture == RIGHT: return "right"
    if gesture == DOWN: return "down"
    if gesture == LEFT: return "left"
    return "unknown ($gesture)"

/**
Converts raw gesture FIFO data into a $Gesture direction.

The datasheet gives no decoding algorithm.  It only says that "Ideally,
  gesture detection works by capturing and comparing the amplitude and phase
  difference between directional sensor results", and that the diode opposite
  to the direction of motion sees the larger share of the reflection on entry
  and the smaller share on exit.

The method used here is an estimate, modelled on how common Arduino libraries
  are understood to work (recalled, not verified against their source):
  - Datasets where all four channels exceed $threshold are considered part
    of the gesture.
  - For the first and for the last such dataset, a normalised difference is
    computed for each axis: (up - down) * 100 / (up + down), and likewise for
    left and right.
  - The change of that value from first to last dataset is the evidence for
    motion on that axis.  A change of at least $sensitivity percentage points
    counts.  When both axes qualify, the larger change wins.

Near and far gestures (hand moving towards or away from the sensor) are not
  decoded.
*/
class GestureDecoder:
  /**
  The minimum value all four channels need in a dataset for it to be part of
    the gesture.
  */
  threshold/int
  /** The minimum change, in percentage points, that counts as motion. */
  sensitivity/int
  rotation-steps_/int

  /**
  Constructs a decoder.

  The $threshold and $sensitivity default to estimated starting values (10 and
    50) that are expected to need tuning on hardware.

  The $rotation is a multiple of 90.  Every detected direction is turned
    clockwise by that many degrees before it is returned, to compensate for a
    module whose chip is mounted rotated, or for a flipped axis pair.
  */
  constructor --.threshold/int=10 --.sensitivity/int=50 --rotation/int=0:
    if rotation % 90 != 0: throw "INVALID_ARGUMENT"
    rotation-steps_ = (((rotation / 90) % 4) + 4) % 4

  /**
  Decodes the raw $data, a byte array of 4 byte datasets in up, down, left,
    right order, as returned by $Apds9960.read-gesture-data.

  Returns one of the $Gesture constants, or null if no gesture was recognized.
  */
  decode data/ByteArray -> int?:
    count := data.size / 4
    first := -1
    last := -1
    count.repeat: | i |
      base := i * 4
      if data[base] > threshold and data[base + 1] > threshold and data[base + 2] > threshold and data[base + 3] > threshold:
        if first < 0: first = i
        last = i
    if first < 0 or first == last: return null

    ud-delta := (axis-ratio_ data (last * 4) (last * 4 + 1)) - (axis-ratio_ data (first * 4) (first * 4 + 1))
    lr-delta := (axis-ratio_ data (last * 4 + 2) (last * 4 + 3)) - (axis-ratio_ data (first * 4 + 2) (first * 4 + 3))

    ud-hit := ud-delta.abs >= sensitivity
    lr-hit := lr-delta.abs >= sensitivity
    if not ud-hit and not lr-hit: return null

    result/int := ?
    if ud-hit and ((not lr-hit) or ud-delta.abs >= lr-delta.abs):
      result = ud-delta > 0 ? Gesture.DOWN : Gesture.UP
    else:
      result = lr-delta > 0 ? Gesture.RIGHT : Gesture.LEFT
    return (result + rotation-steps_) % 4

  /** Returns the normalised difference of two channels, in percent. */
  axis-ratio_ data/ByteArray a/int b/int -> int:
    return (data[a] - data[b]) * 100 / (data[a] + data[b])

/**
Driver for the APDS-9960.

See the library documentation for an overview.
*/
class Apds9960:
  /** The only I2C address of the chip. */
  static I2C-ADDRESS ::= 0x39
  /** The value of the ID register. */
  static ID-VALUE ::= 0xAB

  // Register list. Addresses 0x00-0x7F are RAM.
  static REG-ENABLE_        ::= 0x80
  static REG-ADC-TIME_      ::= 0x81
  static REG-WAIT-TIME_     ::= 0x83
  static REG-ALS-LOW_       ::= 0x84  // 16-bit, low byte first.
  static REG-ALS-HIGH_      ::= 0x86  // 16-bit, low byte first.
  static REG-PROX-LOW_      ::= 0x89
  static REG-PROX-HIGH_     ::= 0x8B
  static REG-PERS_          ::= 0x8C
  static REG-CONFIG1_       ::= 0x8D
  static REG-PPULSE_        ::= 0x8E
  static REG-CONTROL_       ::= 0x8F
  static REG-CONFIG2_       ::= 0x90
  static REG-ID_            ::= 0x92
  static REG-STATUS_        ::= 0x93
  static REG-COLOR-DATA_    ::= 0x94  // Clear, red, green, blue; 16-bit each.
  static REG-PDATA_         ::= 0x9C
  static REG-POFFSET-UR_    ::= 0x9D
  static REG-POFFSET-DL_    ::= 0x9E
  static REG-CONFIG3_       ::= 0x9F
  static REG-GPENTH_        ::= 0xA0
  static REG-GEXTH_         ::= 0xA1
  static REG-GCONF1_        ::= 0xA2
  static REG-GCONF2_        ::= 0xA3
  static REG-GOFFSET-U_     ::= 0xA4
  static REG-GOFFSET-D_     ::= 0xA5
  static REG-GPULSE_        ::= 0xA6
  static REG-GOFFSET-L_     ::= 0xA7
  static REG-GOFFSET-R_     ::= 0xA9
  static REG-GCONF3_        ::= 0xAA
  static REG-GCONF4_        ::= 0xAB
  static REG-GFLVL_         ::= 0xAE
  static REG-GSTATUS_       ::= 0xAF
  static REG-IFORCE_        ::= 0xE4
  static REG-PICLEAR_       ::= 0xE5
  static REG-CICLEAR_       ::= 0xE6
  static REG-AICLEAR_       ::= 0xE7
  static REG-GFIFO_         ::= 0xFC  // Up, down, left, right.

  // ENABLE register bits.
  static ENABLE-GEN_  ::= 0b01000000
  static ENABLE-PIEN_ ::= 0b00100000
  static ENABLE-AIEN_ ::= 0b00010000
  static ENABLE-WEN_  ::= 0b00001000
  static ENABLE-PEN_  ::= 0b00000100
  static ENABLE-AEN_  ::= 0b00000010
  static ENABLE-PON_  ::= 0b00000001

  // Other register fields.
  static PERS-PPERS_      ::= 0b11110000
  static PERS-APERS_      ::= 0b00001111
  static CONFIG1-WLONG_   ::= 0b00000010
  static PPULSE-LENGTH_   ::= 0b11000000
  static PPULSE-COUNT_    ::= 0b00111111
  static CONTROL-LDRIVE_  ::= 0b11000000
  static CONTROL-PGAIN_   ::= 0b00001100
  static CONTROL-AGAIN_   ::= 0b00000011
  static CONFIG2-PSIEN_   ::= 0b10000000
  static CONFIG2-CPSIEN_  ::= 0b01000000
  static CONFIG2-LEDBOOST_ ::= 0b00110000
  static CONFIG3-PCMP_    ::= 0b00100000
  static CONFIG3-SAI_     ::= 0b00010000
  static CONFIG3-PMASK_   ::= 0b00001111
  static GCONF1-FIFOTH_   ::= 0b11000000
  static GCONF1-EXMSK_    ::= 0b00111100
  static GCONF1-EXPERS_   ::= 0b00000011
  static GCONF2-GGAIN_    ::= 0b01100000
  static GCONF2-GLDRIVE_  ::= 0b00011000
  static GCONF2-GWTIME_   ::= 0b00000111
  static GCONF3-GDIMS_    ::= 0b00000011
  static GCONF4-FIFO-CLR_ ::= 0b00000100
  static GCONF4-GIEN_     ::= 0b00000010
  static GCONF4-GMODE_    ::= 0b00000001
  static GSTATUS-GFOV_    ::= 0b00000010
  static GSTATUS-GVALID_  ::= 0b00000001

  /** Status bit: clear photodiode saturation. See $status. */
  static STATUS-CPSAT ::= 0b10000000
  /** Status bit: proximity or gesture analog saturation. See $status. */
  static STATUS-PGSAT ::= 0b01000000
  /** Status bit: proximity interrupt. See $status. */
  static STATUS-PINT  ::= 0b00100000
  /** Status bit: ALS interrupt. See $status. */
  static STATUS-AINT  ::= 0b00010000
  /** Status bit: gesture interrupt. See $status. */
  static STATUS-GINT  ::= 0b00000100
  /** Status bit: proximity data valid. See $status. */
  static STATUS-PVALID ::= 0b00000010
  /** Status bit: ALS data valid. See $status. */
  static STATUS-AVALID ::= 0b00000001

  // Field values.

  /** ALS and colour gain 1x, for $set-als-gain. */
  static ALS-GAIN-1X  ::= 0
  /** ALS and colour gain 4x, for $set-als-gain. */
  static ALS-GAIN-4X  ::= 1
  /** ALS and colour gain 16x, for $set-als-gain. */
  static ALS-GAIN-16X ::= 2
  /** ALS and colour gain 64x, for $set-als-gain. */
  static ALS-GAIN-64X ::= 3

  /** Proximity or gesture gain 1x. */
  static GAIN-1X ::= 0
  /** Proximity or gesture gain 2x. */
  static GAIN-2X ::= 1
  /** Proximity or gesture gain 4x. */
  static GAIN-4X ::= 2
  /** Proximity or gesture gain 8x. */
  static GAIN-8X ::= 3

  /** LED drive current of 100 mA. */
  static LED-DRIVE-100MA  ::= 0
  /** LED drive current of 50 mA. */
  static LED-DRIVE-50MA   ::= 1
  /** LED drive current of 25 mA. */
  static LED-DRIVE-25MA   ::= 2
  /** LED drive current of 12.5 mA. */
  static LED-DRIVE-12-5MA ::= 3

  /** LED boost of 100%, which means no additional current. */
  static LED-BOOST-100 ::= 0
  /** LED boost of 150%. */
  static LED-BOOST-150 ::= 1
  /** LED boost of 200%. */
  static LED-BOOST-200 ::= 2
  /** LED boost of 300%. */
  static LED-BOOST-300 ::= 3

  /** LED pulse length of 4 microseconds. */
  static PULSE-LENGTH-4US  ::= 0
  /** LED pulse length of 8 microseconds. */
  static PULSE-LENGTH-8US  ::= 1
  /** LED pulse length of 16 microseconds. */
  static PULSE-LENGTH-16US ::= 2
  /** LED pulse length of 32 microseconds. */
  static PULSE-LENGTH-32US ::= 3

  /** Gesture dimensions: both photodiode pairs are active. */
  static GESTURE-DIMENSIONS-BOTH       ::= 0
  /** Gesture dimensions: only the up-down pair is active. */
  static GESTURE-DIMENSIONS-UP-DOWN    ::= 1
  /** Gesture dimensions: only the left-right pair is active. */
  static GESTURE-DIMENSIONS-LEFT-RIGHT ::= 2

  /** Gesture exit mask bit for the right photodiode. See $set-gesture-exit-mask. */
  static EXIT-MASK-RIGHT ::= 0b0001
  /** Gesture exit mask bit for the left photodiode. */
  static EXIT-MASK-LEFT  ::= 0b0010
  /** Gesture exit mask bit for the down photodiode. */
  static EXIT-MASK-DOWN  ::= 0b0100
  /** Gesture exit mask bit for the up photodiode. */
  static EXIT-MASK-UP    ::= 0b1000

  /** The duration of one ADC or wait cycle, in milliseconds (2.78 ms). */
  static CYCLE-MS_ ::= 2.78

  static DEFAULT-GESTURE-TIMEOUT_ ::= Duration --s=1
  static GESTURE-POLL-MS_ ::= 10

  dev_/serial.Device
  reg_/registers.Registers
  logger_/log.Logger

  /**
  Constructs a driver for the given device.

  Reads the ID register and throws "UNEXPECTED_DEVICE_ID" if it is not
    $ID-VALUE.  Pass --no-verify-id to skip the check, for example for a clone
    that reports another ID.

  The constructor does not change the configuration of the chip.
  */
  constructor dev/serial.Device --logger/log.Logger=log.default --verify-id/bool=true:
    dev_ = dev
    reg_ = dev.registers
    logger_ = logger.with-name "apds9960"
    if verify-id:
      id := reg_.read-u8 REG-ID_
      if id != ID-VALUE:
        logger_.error "unexpected device id" --tags={"id": "0x$(%02x id)"}
        throw "UNEXPECTED_DEVICE_ID"

  /** Returns the raw content of the ID register. $ID-VALUE is expected. */
  device-id -> int:
    return reg_.read-u8 REG-ID_

  // Power and engine enables.

  /**
  Switches the internal oscillator on.

  The oscillator must run for timers and ADC channels to operate.  Register
    access over I2C works regardless of this setting.
  */
  power-on -> none:
    set-bit_ REG-ENABLE_ ENABLE-PON_ true

  /** Switches the oscillator off, which puts the chip in a low power sleep mode. */
  power-off -> none:
    set-bit_ REG-ENABLE_ ENABLE-PON_ false

  /** Whether the oscillator is on. */
  powered-on -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-PON_

  /** Enables the ALS and colour engine. */
  enable-als -> none:
    set-bit_ REG-ENABLE_ ENABLE-AEN_ true

  /** Disables the ALS and colour engine. */
  disable-als -> none:
    set-bit_ REG-ENABLE_ ENABLE-AEN_ false

  /** Whether the ALS and colour engine is enabled. */
  als-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-AEN_

  /** Enables the proximity engine, which the gesture engine also needs. */
  enable-proximity -> none:
    set-bit_ REG-ENABLE_ ENABLE-PEN_ true

  /** Disables the proximity engine. */
  disable-proximity -> none:
    set-bit_ REG-ENABLE_ ENABLE-PEN_ false

  /** Whether the proximity engine is enabled. */
  proximity-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-PEN_

  /**
  Enables the gesture engine.

  The datasheet says that "the Gesture engine is entered when its enable bit,
    GEN, and the operating mode bit, GMODE, are both set".  GMODE is set by the
    chip when the proximity reading reaches the entry threshold set with
    $set-gesture-entry-threshold, so the proximity engine must be enabled as
    well.
  */
  enable-gesture -> none:
    set-bit_ REG-ENABLE_ ENABLE-GEN_ true

  /** Disables the gesture engine. */
  disable-gesture -> none:
    set-bit_ REG-ENABLE_ ENABLE-GEN_ false

  /** Whether the gesture engine is enabled. */
  gesture-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-GEN_

  /** Enables the wait timer, which adds a pause between proximity and ALS cycles. */
  enable-wait-timer -> none:
    set-bit_ REG-ENABLE_ ENABLE-WEN_ true

  /** Disables the wait timer. */
  disable-wait-timer -> none:
    set-bit_ REG-ENABLE_ ENABLE-WEN_ false

  /** Whether the wait timer is enabled. */
  wait-timer-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-WEN_

  // Timing.

  /**
  Sets the ALS and colour integration time as a number of cycles.

  The $cycles are between 1 and 256, and one cycle is 2.78 ms.  The register
    holds 256 - $cycles.  See $als-max-count for the resulting maximum count.
  */
  set-integration-cycles cycles/int -> none:
    if not 1 <= cycles <= 256: throw "OUT_OF_RANGE"
    reg_.write-u8 REG-ADC-TIME_ (256 - cycles)

  /** The ALS and colour integration time, in cycles. See $set-integration-cycles. */
  integration-cycles -> int:
    return 256 - (reg_.read-u8 REG-ADC-TIME_)

  /**
  Sets the ALS and colour integration time to the nearest possible value for
    the given milliseconds ($ms).
  */
  set-integration-time --ms/num -> none:
    cycles := (ms / CYCLE-MS_).round
    set-integration-cycles (max 1 (min 256 cycles))

  /** The ALS and colour integration time, in milliseconds. */
  integration-time-ms -> float:
    return integration-cycles * CYCLE-MS_

  /**
  The largest value a colour channel can reach with the current integration
    time.

  This is the lesser of 65535 and 1 + 1024 times the number of cycles.  A
    channel at this value is saturated.

  The datasheet text gives the equation "CountMAX = 1025 x CYCLES", but its
    table lists 1025, 10241 and 37889 for 1, 10 and 37 cycles, which fit
    1 + 1024 x CYCLES and not the equation.  The table values are used.
  */
  als-max-count -> int:
    return min 65535 (1 + 1024 * integration-cycles)

  /**
  Sets the wait time as a number of cycles between 1 and 256.

  One cycle is 2.78 ms, or 12 times that with $enable-wait-long.  The register
    holds 256 - $cycles.  The wait time only applies when the wait timer is
    enabled.
  */
  set-wait-cycles cycles/int -> none:
    if not 1 <= cycles <= 256: throw "OUT_OF_RANGE"
    reg_.write-u8 REG-WAIT-TIME_ (256 - cycles)

  /** The wait time in cycles. See $set-wait-cycles. */
  wait-cycles -> int:
    return 256 - (reg_.read-u8 REG-WAIT-TIME_)

  /** The wait time in milliseconds, including the effect of $wait-long-enabled. */
  wait-time-ms -> float:
    time := wait-cycles * CYCLE-MS_
    if wait-long-enabled: time *= 12
    return time

  /** Multiplies all wait times by 12. */
  enable-wait-long -> none:
    set-bit_ REG-CONFIG1_ CONFIG1-WLONG_ true

  /** Returns wait times to the normal length. */
  disable-wait-long -> none:
    set-bit_ REG-CONFIG1_ CONFIG1-WLONG_ false

  /** Whether wait times are multiplied by 12. */
  wait-long-enabled -> bool:
    return get-bit_ REG-CONFIG1_ CONFIG1-WLONG_

  // Gain, LED and pulses.

  /** Sets the ALS and colour gain to one of the ALS-GAIN constants, for example $ALS-GAIN-4X. */
  set-als-gain gain/int -> none:
    write-field_ REG-CONTROL_ CONTROL-AGAIN_ gain

  /** The ALS and colour gain, as one of the ALS-GAIN constants. */
  als-gain -> int:
    return read-field_ REG-CONTROL_ CONTROL-AGAIN_

  /** Sets the proximity gain to one of the GAIN constants, for example $GAIN-4X. */
  set-proximity-gain gain/int -> none:
    write-field_ REG-CONTROL_ CONTROL-PGAIN_ gain

  /** The proximity gain, as one of the GAIN constants. */
  proximity-gain -> int:
    return read-field_ REG-CONTROL_ CONTROL-PGAIN_

  /**
  Sets the LED drive current for proximity to one of the LED-DRIVE constants.

  The gesture engine has its own setting, see $set-gesture-led-drive.
  */
  set-led-drive drive/int -> none:
    write-field_ REG-CONTROL_ CONTROL-LDRIVE_ drive

  /** The LED drive current for proximity, as one of the LED-DRIVE constants. */
  led-drive -> int:
    return read-field_ REG-CONTROL_ CONTROL-LDRIVE_

  /**
  Sets the additional LED current for proximity and gesture to one of the
    LED-BOOST constants.

  The datasheet says the boost raises the current "by the percentage of
    LED_BOOST", for example to reach further or to work behind dark glass.
  */
  set-led-boost boost/int -> none:
    write-field_ REG-CONFIG2_ CONFIG2-LEDBOOST_ boost

  /** The LED boost, as one of the LED-BOOST constants. */
  led-boost -> int:
    return read-field_ REG-CONFIG2_ CONFIG2-LEDBOOST_

  /**
  Sets the proximity LED pulse train.

  The $count is between 1 and 64 pulses.  The $length is one of the
    PULSE-LENGTH constants.
  */
  set-proximity-pulses --count/int --length/int -> none:
    reg_.write-u8 REG-PPULSE_ (pulse-byte_ count length)

  /**
  Sets the proximity offsets, which compensate cross-talk.

  The offsets for the up and right photodiodes share one register, and the
    ones for down and left share another.  Values are between -127 and 127.
  */
  set-proximity-offsets --up-right/int --down-left/int -> none:
    reg_.write-u8 REG-POFFSET-UR_ (encode-offset_ up-right)
    reg_.write-u8 REG-POFFSET-DL_ (encode-offset_ down-left)

  /** The proximity offset for the up and right photodiodes. */
  proximity-offset-up-right -> int:
    return decode-offset_ (reg_.read-u8 REG-POFFSET-UR_)

  /** The proximity offset for the down and left photodiodes. */
  proximity-offset-down-left -> int:
    return decode-offset_ (reg_.read-u8 REG-POFFSET-DL_)

  /**
  Selects which photodiodes contribute to proximity.

  A photodiode given as false is disabled.  With a single diode of a pair
    active, $enable-proximity-gain-compensation restores the full range.
  */
  set-proximity-photodiodes --up/bool=true --down/bool=true --left/bool=true --right/bool=true -> none:
    // A set bit in the register disables the photodiode.
    mask := (up ? 0 : 0b1000) | (down ? 0 : 0b0100) | (left ? 0 : 0b0010) | (right ? 0 : 0b0001)
    write-field_ REG-CONFIG3_ CONFIG3-PMASK_ mask

  /**
  Doubles the proximity gain.

  The datasheet says: "If only one diode of the diode pair is contributing,
    then only half of the signal is available at the ADC; this results in a
    maximum ADC value of 127. Enabling PCMP enables an additional gain of 2X,
    resulting in a maximum ADC value of 255."
  */
  enable-proximity-gain-compensation -> none:
    set-bit_ REG-CONFIG3_ CONFIG3-PCMP_ true

  /** Switches off the gain compensation of $enable-proximity-gain-compensation. */
  disable-proximity-gain-compensation -> none:
    set-bit_ REG-CONFIG3_ CONFIG3-PCMP_ false

  // Readings.

  /** Whether a new ALS and colour reading has completed. */
  color-valid -> bool:
    return get-bit_ REG-STATUS_ STATUS-AVALID

  /**
  Reads the clear, red, green and blue channels.

  Reads all eight bytes in one transaction starting at the clear channel's low
    byte.  The datasheet says reading that low byte "also latches all eight
    RGBC register simultaneously", so the four values belong together.
  */
  read-color -> ColorData:
    raw := reg_.read-bytes REG-COLOR-DATA_ 8
    return ColorData
        --clear=(raw[0] | (raw[1] << 8))
        --red=(raw[2] | (raw[3] << 8))
        --green=(raw[4] | (raw[5] << 8))
        --blue=(raw[6] | (raw[7] << 8))

  /** Whether a new proximity reading has completed since the last $read-proximity. */
  proximity-valid -> bool:
    return get-bit_ REG-STATUS_ STATUS-PVALID

  /**
  Reads the proximity value, between 0 and 255.

  A higher value means a closer object.  Reading clears the valid flag.
  */
  read-proximity -> int:
    return reg_.read-u8 REG-PDATA_

  // Interrupts.

  /**
  The raw status register.

  Use the STATUS constants, for example $STATUS-PINT, to test bits.  Testing
    several bits from one read is cheaper and consistent compared with calling
    the individual getters.
  */
  status -> int:
    return reg_.read-u8 REG-STATUS_

  /** Whether the proximity interrupt flag is set. */
  proximity-interrupt-pending -> bool:
    return get-bit_ REG-STATUS_ STATUS-PINT

  /** Whether the ALS interrupt flag is set. */
  als-interrupt-pending -> bool:
    return get-bit_ REG-STATUS_ STATUS-AINT

  /** Whether the gesture interrupt flag is set. */
  gesture-interrupt-pending -> bool:
    return get-bit_ REG-STATUS_ STATUS-GINT

  /**
  Lets the proximity engine raise interrupts on the INT pin.

  Interrupts are raised when the proximity value is outside the thresholds from
    $set-proximity-thresholds for as many consecutive cycles as the persistence
    from $set-proximity-persistence demands.
  */
  enable-proximity-interrupt -> none:
    set-bit_ REG-ENABLE_ ENABLE-PIEN_ true

  /** Stops proximity interrupts. */
  disable-proximity-interrupt -> none:
    set-bit_ REG-ENABLE_ ENABLE-PIEN_ false

  /** Whether proximity interrupts are enabled. */
  proximity-interrupt-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-PIEN_

  /**
  Lets the ALS engine raise interrupts on the INT pin.

  Interrupts are raised when the clear channel is outside the thresholds from
    $set-als-thresholds for as many consecutive cycles as the persistence from
    $set-als-persistence demands.
  */
  enable-als-interrupt -> none:
    set-bit_ REG-ENABLE_ ENABLE-AIEN_ true

  /** Stops ALS interrupts. */
  disable-als-interrupt -> none:
    set-bit_ REG-ENABLE_ ENABLE-AIEN_ false

  /** Whether ALS interrupts are enabled. */
  als-interrupt-enabled -> bool:
    return get-bit_ REG-ENABLE_ ENABLE-AIEN_

  /** Raises an interrupt on the INT pin, regardless of the thresholds. */
  force-interrupt -> none:
    command_ REG-IFORCE_

  /**
  Clears the proximity interrupt.

  Uses the special two byte transaction that the datasheet describes: "chip
    address with R/W = 0, followed by a register address."
  */
  clear-proximity-interrupt -> none:
    command_ REG-PICLEAR_

  /** Clears the ALS interrupt. See $clear-proximity-interrupt. */
  clear-als-interrupt -> none:
    command_ REG-CICLEAR_

  /**
  Clears all interrupts except the gesture interrupt.

  The gesture interrupt flags clear when the FIFO has been emptied, see
    $read-gesture-data.
  */
  clear-all-interrupts -> none:
    command_ REG-AICLEAR_

  /** Sets the low and high thresholds for ALS interrupts, 16-bit values on the clear channel. */
  set-als-thresholds --low/int --high/int -> none:
    if not 0 <= low <= 0xFFFF or not 0 <= high <= 0xFFFF: throw "OUT_OF_RANGE"
    reg_.write-u16-le REG-ALS-LOW_ low
    reg_.write-u16-le REG-ALS-HIGH_ high

  /** The low threshold for ALS interrupts. */
  als-low-threshold -> int:
    return reg_.read-u16-le REG-ALS-LOW_

  /** The high threshold for ALS interrupts. */
  als-high-threshold -> int:
    return reg_.read-u16-le REG-ALS-HIGH_

  /** Sets the low and high thresholds for proximity interrupts, 8-bit values. */
  set-proximity-thresholds --low/int --high/int -> none:
    if not 0 <= low <= 0xFF or not 0 <= high <= 0xFF: throw "OUT_OF_RANGE"
    reg_.write-u8 REG-PROX-LOW_ low
    reg_.write-u8 REG-PROX-HIGH_ high

  /** The low threshold for proximity interrupts. */
  proximity-low-threshold -> int:
    return reg_.read-u8 REG-PROX-LOW_

  /** The high threshold for proximity interrupts. */
  proximity-high-threshold -> int:
    return reg_.read-u8 REG-PROX-HIGH_

  /**
  Sets the proximity interrupt persistence to the register value $value, 0 to 15.

  Per the datasheet 0 means every proximity cycle, 1 means any value outside
    the thresholds, and N from 2 to 15 means N consecutive values outside.
  */
  set-proximity-persistence value/int -> none:
    write-field_ REG-PERS_ PERS-PPERS_ value

  /** The proximity interrupt persistence register value. */
  proximity-persistence -> int:
    return read-field_ REG-PERS_ PERS-PPERS_

  /**
  Sets the ALS interrupt persistence to the register value $value, 0 to 15.

  Per the datasheet 0 means every ALS cycle, 1 means any value outside the
    thresholds, 2 and 3 mean that many consecutive values, and 4 to 15 mean
    5, 10, 15 and so on in steps of 5 up to 60 consecutive values.
  */
  set-als-persistence value/int -> none:
    write-field_ REG-PERS_ PERS-APERS_ value

  /** The ALS interrupt persistence register value. */
  als-persistence -> int:
    return read-field_ REG-PERS_ PERS-APERS_

  /** Lets proximity saturation raise an interrupt. */
  enable-proximity-saturation-interrupt -> none:
    set-bit_ REG-CONFIG2_ CONFIG2-PSIEN_ true

  /** Stops proximity saturation interrupts. */
  disable-proximity-saturation-interrupt -> none:
    set-bit_ REG-CONFIG2_ CONFIG2-PSIEN_ false

  /** Lets clear channel saturation raise an interrupt. */
  enable-als-saturation-interrupt -> none:
    set-bit_ REG-CONFIG2_ CONFIG2-CPSIEN_ true

  /** Stops clear channel saturation interrupts. */
  disable-als-saturation-interrupt -> none:
    set-bit_ REG-CONFIG2_ CONFIG2-CPSIEN_ false

  /**
  Lets the chip sleep after an interrupt is raised.

  Per the datasheet, normal operation resumes when the INT pin is cleared over
    I2C.
  */
  enable-sleep-after-interrupt -> none:
    set-bit_ REG-CONFIG3_ CONFIG3-SAI_ true

  /** Disables sleep after interrupt. */
  disable-sleep-after-interrupt -> none:
    set-bit_ REG-CONFIG3_ CONFIG3-SAI_ false

  // Gesture configuration.

  /**
  Sets the proximity value at which the gesture engine is entered.

  The datasheet's description of this register ends with the note "Bit 4 must
    be set to 0."  It is unclear whether that applies to this register, and the
    value is not restricted here.
  */
  set-gesture-entry-threshold value/int -> none:
    if not 0 <= value <= 0xFF: throw "OUT_OF_RANGE"
    reg_.write-u8 REG-GPENTH_ value

  /** The gesture entry threshold. */
  gesture-entry-threshold -> int:
    return reg_.read-u8 REG-GPENTH_

  /**
  Sets the value at which the gesture engine is exited.

  The datasheet says: "Setting GTHR_OUT to 0x00 will prevent gesture exit until
    GMODE is set to 0."
  */
  set-gesture-exit-threshold value/int -> none:
    if not 0 <= value <= 0xFF: throw "OUT_OF_RANGE"
    reg_.write-u8 REG-GEXTH_ value

  /** The gesture exit threshold. */
  gesture-exit-threshold -> int:
    return reg_.read-u8 REG-GEXTH_

  /**
  Sets how many datasets in the FIFO raise the gesture interrupt.

  The $datasets are 1, 4, 8 or 16.
  */
  set-gesture-fifo-threshold datasets/int -> none:
    value := ?
    if datasets == 1: value = 0
    else if datasets == 4: value = 1
    else if datasets == 8: value = 2
    else if datasets == 16: value = 3
    else: throw "OUT_OF_RANGE"
    write-field_ REG-GCONF1_ GCONF1-FIFOTH_ value

  /** The gesture FIFO interrupt threshold, in datasets. */
  gesture-fifo-threshold -> int:
    return [1, 4, 8, 16][read-field_ REG-GCONF1_ GCONF1-FIFOTH_]

  /**
  Sets which photodiodes are left out when judging whether a gesture has ended.

  The $mask combines the EXIT-MASK constants, for example $EXIT-MASK-UP.  Zero
    includes all four photodiodes.
  */
  set-gesture-exit-mask mask/int -> none:
    write-field_ REG-GCONF1_ GCONF1-EXMSK_ mask

  /** The gesture exit mask. */
  gesture-exit-mask -> int:
    return read-field_ REG-GCONF1_ GCONF1-EXMSK_

  /**
  Sets the gesture exit persistence to the register value $value, 0 to 3.

  Per the datasheet the engine is left at the 1st, 2nd, 4th or 7th "gesture
    end" occurrence for the values 0, 1, 2 and 3.
  */
  set-gesture-exit-persistence value/int -> none:
    write-field_ REG-GCONF1_ GCONF1-EXPERS_ value

  /** The gesture exit persistence register value. */
  gesture-exit-persistence -> int:
    return read-field_ REG-GCONF1_ GCONF1-EXPERS_

  /** Sets the gesture gain to one of the GAIN constants, for example $GAIN-4X. */
  set-gesture-gain gain/int -> none:
    write-field_ REG-GCONF2_ GCONF2-GGAIN_ gain

  /** The gesture gain, as one of the GAIN constants. */
  gesture-gain -> int:
    return read-field_ REG-GCONF2_ GCONF2-GGAIN_

  /** Sets the gesture LED drive current to one of the LED-DRIVE constants. */
  set-gesture-led-drive drive/int -> none:
    write-field_ REG-GCONF2_ GCONF2-GLDRIVE_ drive

  /** The gesture LED drive current, as one of the LED-DRIVE constants. */
  gesture-led-drive -> int:
    return read-field_ REG-GCONF2_ GCONF2-GLDRIVE_

  /**
  Sets the pause between gesture cycles to the register value $value, 0 to 7.

  Per the datasheet the values 0 to 7 mean 0, 2.8, 5.6, 8.4, 14.0, 22.4, 30.8
    and 39.2 ms.  The datasheet adds that this "should be configured before GEN
    is asserted".
  */
  set-gesture-wait-time value/int -> none:
    write-field_ REG-GCONF2_ GCONF2-GWTIME_ value

  /** The gesture wait time register value. */
  gesture-wait-time -> int:
    return read-field_ REG-GCONF2_ GCONF2-GWTIME_

  /**
  Sets the gesture LED pulse train.

  The $count is between 1 and 64 pulses.  The $length is one of the
    PULSE-LENGTH constants.
  */
  set-gesture-pulses --count/int --length/int -> none:
    reg_.write-u8 REG-GPULSE_ (pulse-byte_ count length)

  /**
  Sets the gesture offsets, which compensate cross-talk for each photodiode.

  Values are between -127 and 127.  A positive value decreases the result,
    per the datasheet.
  */
  set-gesture-offsets --up/int --down/int --left/int --right/int -> none:
    reg_.write-u8 REG-GOFFSET-U_ (encode-offset_ up)
    reg_.write-u8 REG-GOFFSET-D_ (encode-offset_ down)
    reg_.write-u8 REG-GOFFSET-L_ (encode-offset_ left)
    reg_.write-u8 REG-GOFFSET-R_ (encode-offset_ right)

  /** The gesture offsets, as a list in the order up, down, left, right. */
  gesture-offsets -> List:
    return [
      decode-offset_ (reg_.read-u8 REG-GOFFSET-U_),
      decode-offset_ (reg_.read-u8 REG-GOFFSET-D_),
      decode-offset_ (reg_.read-u8 REG-GOFFSET-L_),
      decode-offset_ (reg_.read-u8 REG-GOFFSET-R_),
    ]

  /**
  Selects which photodiode pairs gather gesture data.

  The $dimensions are one of the GESTURE-DIMENSIONS constants.  With a single
    pair the data of the other pair is invalid, and per the datasheet the pair
    in use "collects data twice as fast".
  */
  set-gesture-dimensions dimensions/int -> none:
    write-field_ REG-GCONF3_ GCONF3-GDIMS_ dimensions

  /** The gesture dimensions, as one of the GESTURE-DIMENSIONS constants. */
  gesture-dimensions -> int:
    return read-field_ REG-GCONF3_ GCONF3-GDIMS_

  /** Lets gesture FIFO data raise an interrupt on the INT pin. */
  enable-gesture-interrupt -> none:
    set-bit_ REG-GCONF4_ GCONF4-GIEN_ true

  /** Stops gesture interrupts on the INT pin. */
  disable-gesture-interrupt -> none:
    set-bit_ REG-GCONF4_ GCONF4-GIEN_ false

  /** Whether gesture interrupts are enabled. */
  gesture-interrupt-enabled -> bool:
    return get-bit_ REG-GCONF4_ GCONF4-GIEN_

  /**
  Makes the gesture engine start, as if the entry threshold had been reached.

  The engine only runs if $enable-gesture was called.
  */
  enter-gesture-mode -> none:
    set-bit_ REG-GCONF4_ GCONF4-GMODE_ true

  /** Makes the gesture engine stop once the current conversion has finished. */
  exit-gesture-mode -> none:
    set-bit_ REG-GCONF4_ GCONF4-GMODE_ false

  /** Whether the gesture engine is currently running. */
  gesture-mode-active -> bool:
    return get-bit_ REG-GCONF4_ GCONF4-GMODE_

  /**
  Empties the gesture FIFO and clears the gesture flags.

  Also leaves gesture mode, as the write sets the mode bit to 0.  The
    interrupt enable setting is kept.
  */
  clear-gesture-fifo -> none:
    gien := (reg_.read-u8 REG-GCONF4_) & GCONF4-GIEN_
    reg_.write-u8 REG-GCONF4_ (gien | GCONF4-FIFO-CLR_)

  // Gesture data.

  /** The number of datasets in the gesture FIFO. */
  gesture-fifo-level -> int:
    return reg_.read-u8 REG-GFLVL_

  /** Whether the FIFO holds enough data to raise a gesture interrupt. */
  gesture-valid -> bool:
    return get-bit_ REG-GSTATUS_ GSTATUS-GVALID_

  /**
  Whether the FIFO has overflowed.

  The datasheet says that when this happens "new gesture detector data has
    been lost".
  */
  gesture-fifo-overflow -> bool:
    return get-bit_ REG-GSTATUS_ GSTATUS-GFOV_

  /**
  Reads datasets from the gesture FIFO, at most $max-datasets of them.

  Returns a byte array with four bytes per dataset, in the order up, down,
    left, right.  Each dataset is read with a four byte transaction that ends at
    the right channel's address, which is what advances the chip's FIFO
    pointer.  The result is empty if the FIFO is empty.  Emptying the FIFO
    clears the gesture interrupt flags.
  */
  read-gesture-data --max-datasets/int=32 -> ByteArray:
    count := min gesture-fifo-level max-datasets
    result := ByteArray count * 4
    count.repeat: | i |
      result.replace (i * 4) (reg_.read-bytes REG-GFIFO_ 4)
    return result

  /**
  Collects the datasets of one complete gesture.

  Waits up to the $timeout for the gesture engine to start, polling every few
    milliseconds, then reads the FIFO until the engine has stopped and the FIFO
    is empty.  Returns the datasets as in $read-gesture-data, or null if no
    gesture started within the $timeout.  The collection itself is limited to
    two seconds.

  The FIFO holds 32 datasets and overflows when it is not read in time, so
    this method should not be starved by other work.
  */
  collect-gesture-data --timeout/Duration=DEFAULT-GESTURE-TIMEOUT_ -> ByteArray?:
    deadline := Time.monotonic-us + timeout.in-us
    while not (gesture-mode-active or gesture-fifo-level > 0):
      if Time.monotonic-us >= deadline: return null
      sleep --ms=GESTURE-POLL-MS_
    buffer := io.Buffer
    limit := Time.monotonic-us + 2_000_000
    while true:
      // The mode is read before the level, so data that arrives with the
      // engine's exit is not missed.
      active := gesture-mode-active
      level := gesture-fifo-level
      if level > 0:
        buffer.write (read-gesture-data)
        continue
      if not active: break
      if Time.monotonic-us >= limit: break
      sleep --ms=GESTURE-POLL-MS_
    return buffer.bytes

  /**
  Waits for a gesture and decodes it.

  Returns one of the $Gesture constants, or null if no gesture started within
    the $timeout or the datasets did not amount to a recognizable gesture.  The
    $decoder defaults to a $GestureDecoder with its default settings.
  */
  read-gesture --timeout/Duration=DEFAULT-GESTURE-TIMEOUT_ --decoder/GestureDecoder?=null -> int?:
    data := collect-gesture-data --timeout=timeout
    if data == null: return null
    return (decoder or GestureDecoder).decode data

  // Starting values.

  /**
  Applies starting values for colour and ambient light.

  An integration time of 103 ms (37 cycles) and a gain of 4x.  These are
    estimated values, taken from what common Arduino libraries are understood to
    use, and are meant to be adjusted.
  */
  set-color-defaults -> none:
    set-integration-cycles 37
    set-als-gain ALS-GAIN-4X

  /**
  Applies starting values for proximity.

  Eight 16 microsecond pulses, 4x gain and 100 mA LED current.  Estimated
    values, see $set-color-defaults.
  */
  set-proximity-defaults -> none:
    set-proximity-pulses --count=8 --length=PULSE-LENGTH-16US
    set-proximity-gain GAIN-4X
    set-led-drive LED-DRIVE-100MA

  /**
  Applies starting values for the gesture engine.

  The entry threshold is 40, the exit threshold 30, the FIFO threshold 4
    datasets, exit persistence register value 1, gain 4x, LED current 100 mA, a
    wait of 2.8 ms, ten 32 microsecond pulses, and both photodiode pairs.
    These are estimated values, taken from what common Arduino libraries are
    understood to use, and they will probably need tuning on hardware.

  The gesture engine also needs the proximity engine, so $set-proximity-defaults
    is a sensible companion.  Call before $enable-gesture.
  */
  set-gesture-defaults -> none:
    set-gesture-entry-threshold 40
    set-gesture-exit-threshold 30
    set-gesture-fifo-threshold 4
    set-gesture-exit-mask 0
    set-gesture-exit-persistence 1
    set-gesture-gain GAIN-4X
    set-gesture-led-drive LED-DRIVE-100MA
    set-gesture-wait-time 1
    set-gesture-pulses --count=10 --length=PULSE-LENGTH-32US
    set-gesture-offsets --up=0 --down=0 --left=0 --right=0
    set-gesture-dimensions GESTURE-DIMENSIONS-BOTH

  // Private helpers.

  /** Sends a register address alone, which triggers the special command registers. */
  command_ register/int -> none:
    dev_.write #[register]

  read-field_ register/int mask/int -> int:
    return ((reg_.read-u8 register) & mask) >> mask.count-trailing-zeros

  write-field_ register/int mask/int value/int -> none:
    shift := mask.count-trailing-zeros
    if value < 0 or ((value << shift) & (~mask)) != 0: throw "OUT_OF_RANGE"
    current := reg_.read-u8 register
    reg_.write-u8 register ((current & (~mask)) | (value << shift))

  get-bit_ register/int mask/int -> bool:
    return ((reg_.read-u8 register) & mask) != 0

  set-bit_ register/int mask/int on/bool -> none:
    current := reg_.read-u8 register
    reg_.write-u8 register (on ? (current | mask) : (current & (~mask)))

  pulse-byte_ count/int length/int -> int:
    if not 1 <= count <= 64: throw "OUT_OF_RANGE"
    if not 0 <= length <= 3: throw "OUT_OF_RANGE"
    return (length << 6) | (count - 1)

  /** Encodes a value from -127 to 127 as the sign and magnitude format of the offset registers. */
  encode-offset_ value/int -> int:
    if not -127 <= value <= 127: throw "OUT_OF_RANGE"
    return value >= 0 ? value : (0x80 | -value)

  decode-offset_ raw/int -> int:
    return (raw & 0x80) == 0 ? raw : -(raw & 0x7F)
