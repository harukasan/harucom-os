# Harucom browser Shell (funicular UI). wasm only.
#
# The Engine writes this into MEMFS under /_web/lib and starts it via
# harucom_run_ruby. funicular itself is a gem in libmruby, so no require is
# needed for Funicular::Component. The OS sees /_web in `ls /`; that is accepted
# (see the wasm-funicular plan).
#
# Engine <-> Shell bridge: the Engine exposes window.__harucomBridge carrying
# engine events (stdout lines via takePrints, keyboard debug via keyInfo) and
# commands. Engine -> Shell is poll-based: stdout fires mid-mrb_run_step, so a
# synchronous JS -> Ruby callback would re-enter the VM; instead a background
# task drains the bridge each scheduler pass and patches the App. Shell -> Engine
# (commands) is a direct JS call, which is safe (it only touches C state).

# Console output (replaces #out). pre is not a funicular tag, so a div with a
# whitespace-pre-wrap class stands in.
class ConsolePane < Funicular::Component
  def render
    div(id: "out", class: "console") do
      (props[:lines] || []).join("\n")
    end
  end
end

# Keyboard debug readout (replaces #kbddbg).
class KbdDebug < Funicular::Component
  def render
    div(id: "kbddbg", class: "kbddbg") do
      (props[:info] || "").to_s
    end
  end
end

# Root component: holds the drained engine state and feeds it to the panes.
class Shell < Funicular::Component
  def initialize_state
    { lines: [], key_info: "" }
  end

  def bridge
    b = JS.global[:__harucomBridge]
    b.is_a?(JS::Object) ? b : nil
  end

  # Drain the engine bridge and patch only on change, so funicular re-renders
  # sparingly. Called each scheduler pass by the ui_poll task.
  def tick
    b = bridge
    return unless b
    changes = {}
    fresh = b.takePrints.to_a
    if fresh.length > 0
      merged = state.lines
      i = 0
      while i < fresh.length
        merged = merged + [fresh[i].to_s]
        i += 1
      end
      changes[:lines] = merged.last(500)
    end
    info = b.keyInfo.to_s
    changes[:key_info] = info if info != state.key_info
    patch(changes) unless changes.empty?
  end

  def render
    div(id: "shell", class: "shell") do
      component(ConsolePane, { lines: state.lines })
      component(KbdDebug, { info: state.key_info })
    end
  end
end

shell = Funicular.start(Shell, container: "app")
Task.new(name: "ui_poll") do
  loop do
    shell.tick
    Task.pass
  end
end
