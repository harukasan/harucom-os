# Board::Pad — ADC resistor ladder button input
#
# Each ADC pad has 4 buttons connected via a resistor ladder:
#   Button 0 (right): 1kΩ, Button 1 (up): 2.2kΩ,
#   Button 2 (down): 4.7kΩ, Button 3 (left): 10kΩ
# Pull-up: 1kΩ to 3V3. ADC is 12-bit (0-4095).
#
# The lookup table is computed from measured single-button raw values
# using the parallel resistance formula:
#   conductance_i = 4095.0 / raw_i - 1
#   combo_raw = 4095.0 / (sum(conductance_i) + 1)
#
# Usage:
#   left_pad  = Board::Pad.new(Board::PAD0_PIN)
#   right_pad = Board::Pad.new(Board::PAD1_PIN)
#   left_pad.read
#   left_pad.right?

module Board
  PAD0_PIN = 28
  PAD1_PIN = 29

  class Pad
    # Directions
    RIGHT = 0
    UP    = 1
    DOWN  = 2
    LEFT  = 3

    # Single-button raw values (right, up, down, left)
    DEFAULT_CALIBRATION = [2000, 2760, 3300, 3646]

    # Max_buttons: maximum number of simultaneous button presses to detect
    def initialize(pin, calibration: DEFAULT_CALIBRATION, max_buttons: 2)
      @adc = ADC.new(pin)
      @state = 0
      @raw_value = 0
      @table = build_table(calibration, max_buttons)
    end

    # Read the pad and update internal state.
    # Returns self for chaining.
    def read
      @raw_value = @adc.read_raw
      @state = decode(@raw_value)
      self
    end

    # Check if a button is pressed.
    # button: 0-3 (RIGHT, UP, DOWN, LEFT)
    def pressed?(button)
      (@state & (1 << button)) != 0
    end

    def right? = pressed?(RIGHT)
    def up?    = pressed?(UP)
    def down?  = pressed?(DOWN)
    def left?  = pressed?(LEFT)

    # Returns the raw ADC value.
    def raw
      @raw_value
    end

    # Returns the decoded bitmask.
    def state
      @state
    end

    private

    # Build lookup table from single-button calibration values.
    # Each button's conductance (relative to pull-up) is:
    #   g_i = 4095.0 / raw_i - 1
    # For a combination of pressed buttons:
    #   combo_raw = 4095.0 / (sum(g_i) + 1)
    def build_table(calibration, max_buttons)
      g = calibration.map { |raw| 4095.0 / raw - 1 }
      table = []
      16.times do |mask|
        if mask == 0
          table << [4095, 0]
        else
          # Count pressed buttons in this combination
          count = 0
          4.times { |i| count += 1 if (mask & (1 << i)) != 0 }
          next if count > max_buttons
          s = 0.0
          4.times { |i| s += g[i] if (mask & (1 << i)) != 0 }
          table << [(4095.0 / (s + 1)).to_i, mask]
        end
      end
      table
    end

    # Find the nearest match in the lookup table.
    def decode(raw)
      best_distance = 99999
      best_mask = 0
      @table.each do |expected, mask|
        d = raw - expected
        d = -d if d < 0
        if d < best_distance
          best_distance = d
          best_mask = mask
        end
      end
      best_mask
    end
  end
end
