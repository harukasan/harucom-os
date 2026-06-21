# Browser idle yield for the task scheduler.
#
# On the board, DVI.wait_vsync blocks on a hardware vsync interrupt; the read
# loops in line_editor.rb / irb.rb (`c = read_char; DVI.wait_vsync if !c`) use it
# to idle while waiting for input. There is no vsync in the browser, so the C
# dvi_wait_vsync() is a no-op; override it to suspend the task for about a frame
# instead (sleep_ms is task-aware: mrb_run_step returns, the canvas repaints and
# queued keys are delivered, then the scheduler resumes the task). This keeps
# idle wait loops idle rather than busy-spinning.
#
# Pure-Ruby busy loops with no commit/yield (e.g. a tight compute loop) are kept
# from freezing the tab by the opcode-budget preemption hook installed in
# harucom_init (mrbgems/harucom-os-wasm/src/harucom_wasm.c).
class DVI
  def self.wait_vsync
    sleep_ms 16
  end
end

# Frame pacing for render loops. On the board the app loop runs as fast as the
# CPU while a separate DMA scans the framebuffer at 60Hz and a timer ISR feeds
# audio, so the loop never contends with output. In the browser the synth, the
# canvas blit and the Ruby VM all share one thread, so a render loop that commits
# every iteration (audio_demo, pad_demo, the p5 demos) would redraw far faster
# than 60fps and starve the audio callback. Make commit suspend for a frame so
# those loops run at the display rate (which is all the board shows anyway). The
# preemption hook still covers loops that never commit.
class << DVI::Graphics
  alias_method :commit_without_yield, :commit
  def commit
    commit_without_yield
    DVI.wait_vsync
  end
end

class << DVI::Text
  alias_method :commit_without_yield, :commit
  def commit
    commit_without_yield
    DVI.wait_vsync
  end
end
