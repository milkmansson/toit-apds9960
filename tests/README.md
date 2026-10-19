## Testing

- `tests/apds9960-mock-test.toit` needs no hardware: `toit run tests/apds9960-mock-test.toit`.
- `tests/apds9960-hardware-test.toit` needs a wired module and checks register
  round trips, colour, proximity, the INT pin and, optionally, gestures.
- `tests/apds9960-interrupt-diagnose.toit` needs a wired module and prints the INT
  pin, status flags and readings while the sensor is covered and approached, to
  find out why an interrupt based program stays silent.
