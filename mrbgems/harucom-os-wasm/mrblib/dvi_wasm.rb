# Browser yield point for the cooperative task scheduler.
#
# On the board, DVI.wait_vsync blocks on a hardware vsync interrupt. In the
# browser there is no such interrupt and the single JavaScript thread only
# regains control when a task suspends, so the C dvi_wait_vsync() is an
# intentional no-op (see picoruby-dvi/ports/posix/dvi_wasm.c). Override the
# method here to suspend the task for about one frame instead: sleep_ms is
# task-aware, so mrb_run_step returns, the canvas repaints and queued keyboard
# events are delivered, then the scheduler resumes the task. Without this, the
# read loops in line_editor.rb / edit.rb (`c = read_char; DVI.wait_vsync if !c`)
# would busy-spin and freeze the tab.
#
# The exact cadence depends on how the JS run loop advances the scheduler clock
# (mrb_tick_wasm); 16ms is the nominal 60Hz frame and can be tuned once the
# interactive console is wired up.
class DVI
  def self.wait_vsync
    sleep_ms 16
  end
end
