# Harucom::Engine: the Ruby facade onto the JS Engine. UI components reach the
# devices only through here, never through window.__harucomBridge or
# Module._harucom_* directly.
#
# Engine -> UI is poll-based: the JS bridge buffers stdout lines and the latest
# keyboard / frame / audio readings; poll() drains them each scheduler pass (a
# synchronous JS -> Ruby callback would re-enter the VM mid-mrb_run_step) and
# dispatches to subscribers. UI -> Engine commands (pad_set / start_audio) call
# straight through, since they only touch C state.
#
# The console line buffer lives here, not in the Console panel, so the history
# survives a panel unmount (switching tabs or docks tears the panel down).

module Harucom
  def self.engine
    @engine ||= Engine.new
  end

  class Engine
    CONSOLE_LIMIT = 500

    def initialize
      @subs = {}            # event(Symbol) -> [block]
      @console_lines = []   # accumulated stdout/stderr, capped at CONSOLE_LIMIT
      @key_info = ""
      @frame = 0
      @underruns = 0
    end

    # The bridge the JS Engine exposes on the global, or nil before boot.
    def bridge
      b = JS.global[:__harucomBridge]
      b.is_a?(JS::Object) ? b : nil
    end

    # Subscribe to an engine event (:print, :keys, :frame, :audio). Returns a
    # token to pass to off. Components subscribe through Harucom::UI::Component,
    # which offs the token automatically when they unmount.
    def on(event, &block)
      (@subs[event] ||= []) << block
      [event, block]
    end

    def off(token)
      return unless token
      list = @subs[token[0]]
      list.delete(token[1]) if list
    end

    # Snapshot getters so a freshly mounted panel can render current state before
    # the next poll fires.
    def console_lines
      @console_lines
    end

    def key_info
      @key_info
    end

    def frame
      @frame
    end

    def underruns
      @underruns
    end

    # Drain the bridge once and dispatch any changes. Called each scheduler pass
    # by the ui_poll task in shell.rb.
    def poll
      b = bridge
      return unless b
      drain_prints(b)
      drain_keys(b)
      drain_frame(b)
      drain_audio(b)
    end

    # Commands (UI -> Engine).
    def pad_set(pad, dir, down)
      b = bridge
      b.setPad(pad, dir, down) if b
    end

    def start_audio
      b = bridge
      b.startAudio if b
    end

    private

    def emit(event, value)
      list = @subs[event]
      return unless list
      i = 0
      while i < list.length
        list[i].call(value)
        i += 1
      end
    end

    def drain_prints(b)
      fresh = b.takePrints.to_a
      return if fresh.length == 0
      i = 0
      while i < fresh.length
        @console_lines << fresh[i].to_s
        i += 1
      end
      @console_lines = @console_lines.last(CONSOLE_LIMIT) if @console_lines.length > CONSOLE_LIMIT
      # Emit a fresh array each time so funicular's diff sees a changed value
      # (mutating the stored buffer in place would compare equal).
      emit(:print, @console_lines.dup)
    end

    def drain_keys(b)
      info = b.keyInfo.to_s
      return if info == @key_info
      @key_info = info
      emit(:keys, info)
    end

    def drain_frame(b)
      f = b.frame.to_i
      return if f == @frame
      @frame = f
      emit(:frame, f)
    end

    def drain_audio(b)
      a = b.audio
      u = a[:underruns].to_i
      return if u == @underruns
      @underruns = u
      emit(:audio, u)
    end
  end
end
