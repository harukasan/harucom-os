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

  # Engine teardown: darken the rig, keep the dead-man switch fed
  # while the zero frames reach the fixtures, then stop transmission.
  # Stopping without this leaves the rig lit: fixtures hold their
  # last values when the signal disappears.
  def self.shutdown
    blackout
    8.times do
      keepalive
      sleep_ms 25
    end
    stop
  end
end
