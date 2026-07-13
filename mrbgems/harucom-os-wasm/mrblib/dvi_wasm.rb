# Browser idle yield. The browser has no vsync, so the C dvi_wait_vsync does
# nothing. The input read loops call DVI.wait_vsync to idle while they wait for a
# key. Override it to sleep about one frame. sleep_ms is task-aware, so the task
# really suspends. The browser then repaints the canvas and delivers queued keys.
# Compute loops that never yield are handled by the preemption hook instead.
class DVI
  def self.wait_vsync
    sleep_ms 16
  end
end

# Frame pacing. In the browser the synth, the canvas blit and the VM share one
# thread. A render loop that commits every iteration would redraw far above 60fps
# and starve the audio. audio_demo, pad_demo and the p5 demos do this. So make
# commit suspend for a frame. Those loops then run at the display rate.
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
