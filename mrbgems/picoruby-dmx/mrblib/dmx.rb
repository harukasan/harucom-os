# Keyword front end for the C engine, matching the peripheral gems
# (UART, I2C). The DMX512 line parameters (250000 baud, 8N2) are fixed
# by the standard, so only the wiring is configurable. The engine only
# transmits, so there is no receive pin. Omitted arguments select the
# board default wiring from the board header (the Grove port on the
# Harucom Board).
module DMX
  # Returns the claimed DMA channel number. Raises ArgumentError on an
  # unknown unit and RuntimeError when no DMA channel or alarm pool is
  # available.
  def self.init(unit: nil, txd_pin: -1)
    _init(unit ? unit.to_s : "", txd_pin)
  end
end
