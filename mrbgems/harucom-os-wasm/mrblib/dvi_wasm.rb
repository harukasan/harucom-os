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
# Busy render loops that never call wait_vsync (audio_demo, pad_demo, the p5
# demos) are handled by the opcode-budget preemption hook installed in
# harucom_init (mrbgems/harucom-os-wasm/src/harucom_wasm.c), which makes the wasm
# scheduler preemptive like the board, so those apps need no override here.
class DVI
  def self.wait_vsync
    sleep_ms 16
  end
end
