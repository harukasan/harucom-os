uart = UART.new(unit: :RP2040_UART1,
                txd_pin: 20, rxd_pin: 21,
                baudrate: 250_000, stop_bits: 2)

universe = "\x00" * (512 + 1) # SC + 512ch
universe[3] = 38.chr
universe[14+3] = 38.chr
universe[6] = 100.chr #
universe[14+6] = 100.chr

loop do
  uart.break 1
  uart.write universe
  uart.flush
end
