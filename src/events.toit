// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import gpio
import log
import .apds9960

/**
Interrupt driven callbacks for the APDS-9960.

Import with `import apds9960.events`.  The core $Apds9960 class has no tasks.
  This library is the optional layer that waits on the sensor's INT pin and
  runs lambdas, in the same spirit as the events class of the MPR121 driver.
*/

/**
Runs lambdas when the APDS-9960 raises an interrupt.

The INT pin of the chip is open drain and active low, according to the
  datasheet, so the pin passed in must be an input with a pull-up (either the
  one in the breakout board or $gpio.Pin's own).

A single runner task waits for the pin, then reads the status and calls the
  matching lambda on that task.  A lambda that blocks delays everything else,
  including the reading of the gesture FIFO, which overflows after 32
  datasets.  Lambdas should therefore return quickly or hand work to another
  task.

Only one task should talk to the sensor at a time.  While the runner is
  active, the application should not call the driver for the engines that the
  callbacks serve.  Sharing the I2C bus with other devices is fine.

# Examples
```
events := Apds9960Events driver --intrpt-pin=(gpio.Pin 4 --input --pull-up)
events.on-gesture --callback=(:: | gesture | print (Gesture.name-of gesture))
events.start
```
*/
class Apds9960Events:
  driver_/Apds9960
  pin_/gpio.Pin
  decoder_/GestureDecoder
  logger_/log.Logger
  runner_/Task? := null
  gesture-callback_/Lambda? := null
  proximity-callback_/Lambda? := null
  light-callback_/Lambda? := null

  /**
  Constructs the events for the given $driver, using the INT pin $intrpt-pin.

  The $decoder defaults to a $GestureDecoder with its default settings.
  */
  constructor driver/Apds9960 --intrpt-pin/gpio.Pin --decoder/GestureDecoder?=null --logger/log.Logger=log.default:
    driver_ = driver
    pin_ = intrpt-pin
    decoder_ = decoder or GestureDecoder
    logger_ = logger.with-name "apds9960.events"

  /**
  Sets the lambda to call when a gesture has been recognized.

  The $callback receives one argument, a $Gesture constant.  Needs the
    proximity and gesture engines to be enabled, see $Apds9960.enable-gesture.
    Takes effect at the next $start.
  */
  on-gesture --callback/Lambda? -> none:
    gesture-callback_ = callback

  /**
  Sets the lambda to call when a proximity interrupt is raised.

  The $callback receives one argument, the proximity value.  Thresholds and
    persistence are configured on the driver.  Takes effect at the next $start.
  */
  on-proximity --callback/Lambda? -> none:
    proximity-callback_ = callback

  /**
  Sets the lambda to call when an ALS interrupt is raised.

  The $callback receives one argument, a $ColorData.  Thresholds and
    persistence are configured on the driver.  Takes effect at the next $start.
  */
  on-light --callback/Lambda? -> none:
    light-callback_ = callback

  /** Whether the runner task is running. */
  running -> bool:
    return runner_ != null and not runner_.is-canceled

  /**
  Enables the interrupts that have lambdas and starts the runner task.

  Does nothing if already running.
  */
  start -> none:
    if running: return
    if gesture-callback_: driver_.enable-gesture-interrupt
    else: driver_.disable-gesture-interrupt
    if proximity-callback_: driver_.enable-proximity-interrupt
    else: driver_.disable-proximity-interrupt
    if light-callback_: driver_.enable-als-interrupt
    else: driver_.disable-als-interrupt
    driver_.clear-all-interrupts
    runner_ = task:: run_

  /** Stops the runner task and disables the interrupts again. */
  stop -> none:
    if runner_:
      runner_.cancel
      runner_ = null
    driver_.disable-gesture-interrupt
    driver_.disable-proximity-interrupt
    driver_.disable-als-interrupt
    driver_.clear-all-interrupts

  run_ -> none:
    while true:
      pin_.wait-for 0
      service_
      // Avoid spinning if something keeps the line low.
      if pin_.get == 0: sleep --ms=5

  service_ -> none:
    status := driver_.status
    if (status & Apds9960.STATUS-GINT) != 0 and gesture-callback_:
      data := driver_.collect-gesture-data --timeout=(Duration --ms=500)
      if data != null and data.size > 0:
        gesture := decoder_.decode data
        logger_.debug "gesture" --tags={"datasets": data.size / 4, "gesture": Gesture.name-of gesture}
        if gesture != null: call_ gesture-callback_ gesture
    if (status & Apds9960.STATUS-PINT) != 0 and proximity-callback_:
      call_ proximity-callback_ driver_.read-proximity
    if (status & Apds9960.STATUS-AINT) != 0 and light-callback_:
      call_ light-callback_ driver_.read-color
    // Clears proximity, ALS and saturation flags, so the INT line is released.
    if (status & (Apds9960.STATUS-PINT | Apds9960.STATUS-AINT | Apds9960.STATUS-PGSAT | Apds9960.STATUS-CPSAT)) != 0:
      driver_.clear-all-interrupts

  call_ callback/Lambda argument -> none:
    catch --trace: callback.call argument
