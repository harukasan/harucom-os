# Board::DMX, DMX512 output on the Grove port (J5).
#
# A background engine sends the universe (start code + up to 512 slots)
# at 40 Hz over UART1 TX (GPIO20) through the M5 DMX Unit. Transmission
# uses DMA, so Ruby only updates slot values and never blocks.
#
# Fixtures hold their last values when the signal stops, so the engine
# has a dead-man switch: call keepalive from the main loop, or the
# engine forces every slot to zero after deadman_ms (default 500 ms).
#
# Usage:
#   dmx = Board::DMX.new
#   dmx.start            # begins with all slots at zero
#   dmx[6] = 255         # or dmx.set(6, 255)
#   loop do
#     dmx.keepalive
#     # update values...
#   end
#   dmx.stop             # blacks out, then stops transmission

module Board
  class DMX
    SLOTS = 512

    def initialize
      ::DMX.init
    end

    # Start background transmission. The universe is cleared first to
    # overwrite stale fixture state, so set values after start.
    def start
      ::DMX.start
    end

    # Send zero to every slot, wait for the frames to reach the
    # fixtures, then stop transmission.
    def stop
      ::DMX.blackout
      sleep_ms 100
      ::DMX.stop
    end

    # Set one slot. channel is 1-512, value is 0-255.
    def set(channel, value)
      ::DMX.set(channel, value)
    end

    # Write consecutive slots starting at channel, e.g.
    # set_range(1, [pan, tilt, 0, 0, 0, dimmer]).
    def set_range(channel, values)
      ::DMX.set_range(channel, values)
    end

    def get(channel)
      ::DMX.get(channel)
    end

    def [](channel)
      ::DMX.get(channel)
    end

    def []=(channel, value)
      ::DMX.set(channel, value)
    end

    # Set every slot to zero. The rig goes dark on the next frame.
    def blackout
      ::DMX.blackout
    end

    # Shorten the frame to the number of slots actually used. Shorter
    # frames leave more idle time between frames.
    def active_slots=(count)
      ::DMX.active_slots = count
    end

    # Frames sent since start. Increases at about 40 per second.
    def frame_count
      ::DMX.frame_count
    end

    # Heartbeat for the dead-man switch. Call every main loop iteration.
    def keepalive
      ::DMX.keepalive
    end

    # Grace period before the engine forces the rig dark. 0 disables.
    def deadman_ms=(ms)
      ::DMX.deadman_ms = ms
    end
  end
end
