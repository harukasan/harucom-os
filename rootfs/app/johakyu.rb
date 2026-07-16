# johakyu: live coding UI for sound and light (research 06, M9).
#
# Usage from IRB:
#   johakyu               (untitled buffer seeded from /data/johakyu/starter.rb)
#   johakyu /my/show.rb
#
# Split screen: the top shows the clock, fixtures, and the raw DMX
# universe (changed channels flash inverted); the bottom is a Ruby
# editor reusing the edit.rb behavior (syntax highlight, auto indent,
# undo, IME). The show keeps running while editing: the main loop
# pumps the scheduler and the DMX keepalive on every iteration.
#
# Keybindings:
#   Alt-1..0:   Switch scenes (ten independent buffers, like editor tabs)
#   Ctrl-Enter: Evaluate the buffer (applies at the next cycle boundary)
#   Ctrl-S:     Save (asks for a path when untitled), then evaluate
#   Ctrl-O:     Open a file into the current scene
#   Ctrl-B:     Blackout (running light tracks relight on their next event)
#   Ctrl-Q:     Quit (blackout)
#   Ctrl-Z / Ctrl-Y: Undo / Redo
#
# The buffer is evaluated in a resident Sandbox task. The script only
# records intents through Johakyu::Live; the app task applies them to
# the running session afterwards, so a script error or endless loop
# never breaks the show (see rootfs/lib/johakyu/live.rb).

require "board/pwm_audio"
require "johakyu/live"
require "johakyu/universe_view"

class JohakyuApp
  VIEW_TOP = 0

  STATUS_ATTR  = 0x0F
  COMMAND_ATTR = 0x0F
  EDIT_ATTR    = 0xF0

  UNDO_MAX = 200

  # Runaway-script guard. Fixture definitions are preloaded at
  # startup, but a definition dropped into /data mid-session still
  # parses its JSON inside the eval (a second-plus on the board while
  # sharing the CPU with the show), so the guard leaves headroom over
  # that slowest legitimate eval.
  EVAL_TIMEOUT_MS = 10_000

  # Windowed syntax analysis (same design as edit.rb): only a window
  # of lines around the viewport is parsed, rebuilt on edits or when
  # the viewport leaves the window. Scrolling alone reuses the cached
  # map, so it neither reparses nor reallocates the joined source.
  SYNTAX_MARGIN      = 40
  SYNTAX_ANCHOR_SCAN = 60
  SYNTAX_MAX_BYTES   = 8100
  SYNTAX_PREFETCH_MARGIN = 10 # rebuild ahead when the viewport nears the window edge

  # The syntax parse is an atomic prism call that stalls the show
  # loop, so unlike a standalone editor johakyu cannot afford to run
  # it every idle frame between key repeats. Hold the reparse until
  # the keyboard has been quiet this long; during an active edit the
  # colors stay stale (the text is always correct) and the beat keeps
  # its cadence, then one recolor lands when the hands pause.
  SYNTAX_DEBOUNCE_MS = 140

  # The untitled session is seeded from this show-owned template, so
  # the rig lines live under /data with the rest of the show, not in
  # the app source. It loads as a template: the buffer stays untitled
  # and Ctrl-S will not overwrite it.
  STARTER_PATH = "/data/johakyu/starter.rb"

  # Fallback when no starter is shipped: a sound-only sketch, so the
  # app works on a board with nothing under /data.
  STARTER = [
    "tempo 120",
    "",
    "track(:drums) { sound(\"bd ~ [sd sd] ~, hh*8\") }",
    "",
    "# Alt-1..0 switch scenes, Ctrl-O opens a file; Ctrl-Enter applies the buffer.",
  ]

  SCENE_COUNT = 10

  # One editor tab: its own buffer, file binding, undo history, and
  # viewport. Buffers start untitled with a single empty line.
  class Scene
    attr_accessor :filepath, :scroll_top, :scroll_left
    attr_reader :buffer, :undo_stack, :redo_stack

    def initialize
      @buffer = Editor::Buffer.new
      @buffer.lines.push("")
      @filepath = nil
      @undo_stack = []
      @redo_stack = []
      @scroll_top = 0
      @scroll_left = 0
    end
  end

  def initialize(filepath)
    @console = $console
    @keyboard = $keyboard

    @scenes = Array.new(SCENE_COUNT)
    @scenes[0] = Scene.new
    @scene_index = 0
    scene = @scenes[0]
    @buffer = scene.buffer
    @filepath = filepath
    @undo_stack = scene.undo_stack
    @redo_stack = scene.redo_stack
    @scroll_top = 0
    @scroll_left = 0
    @running = true
    @message = nil
    @syntax = nil     # [highlight_map, window_offsets, win_start] or nil
    @win_start = 0
    @win_end = 0
    @command_bar_text = nil
    @command_bar_mode = false

    @evaling = false
    @eval_started_ms = 0
    @highlight_stale = false
    @stale_syntax = nil       # bundle the screen was drawn with while stale
    @last_key_ms = 0          # for the reparse debounce
    @prefetched_scroll_top = -1
    @split_line = -1
    @join_line = -1
    @eval_compile_ms = 0
    @shown_light_error = nil
    @shown_track_error = nil
    @preedit_width = 0
    @dmx_running = false
  end

  def run
    setup_engine
    @view = Johakyu::UniverseView.new(@session, top: VIEW_TOP)
    apply_layout
    load_buffer
    analyze_viewport

    @sandbox = new_eval_sandbox

    redraw_screen
    @console.commit

    main_loop
  ensure
    shutdown
  end

  # Screen geometry below the universe view. The view height follows
  # the patch, so this is recomputed after every rig swap.
  def apply_layout
    @status_row = VIEW_TOP + @view.rows
    @edit_top = @status_row + 1
    @edit_bottom = Console.rows - 2
    @edit_rows = @edit_bottom - @edit_top + 1
    @command_row = Console.rows - 1
  end

  # Full repaint: universe view furniture, editor lines, and bars.
  def redraw_screen
    @console.clear
    @view.reset
    draw_command_bar
    draw_all_lines
    draw_status
    place_cursor
  end

  private

  def setup_engine
    DMX.init
    DMX.start
    @dmx_running = true
    DMX.deadman_ms = 500
    # The rig is patched by the live script (fixture statements in the
    # buffer); before the first apply there are no slots to shorten to.
    slots = Johakyu.patch.max_channel
    DMX.active_slots = slots if slots > 0
    @audio = Board::PWMAudio.new
    @session = Johakyu::Session.new(audio: @audio, bpm: 120)
    # Attach the drum samples; without this the sound reservations
    # land on sourceless channels and play silence.
    @session.load_kit
    # Parse the OFL definitions and build every mode personality now,
    # on the app task, so fixture statements inside evals resolve
    # from the cache instead of paying the JSON parse and the mode
    # table build against the eval timeout.
    Johakyu.preload_personalities
    @live = Johakyu::Live.new(@session)
    $johakyu_live = @live
  end

  # Runs from the ensure in run, so setup may have failed at any
  # point; only tear down what actually came up, and do not let a
  # teardown error mask the original exception.
  def shutdown
    @sandbox.terminate if @sandbox
    @session.stop_sounds if @session
    @audio.deinit if @audio
    DMX.shutdown if @dmx_running
    @console.hide_cursor
    @console.clear
    @console.commit
  end

  # -- Main loop: the show never waits for a key. --

  def main_loop
    while @running
      @loop_started_ms = Machine.board_millis
      @session.update
      DMX.keepalive
      poll_eval

      c = @keyboard.read_char
      if c
        @last_key_ms = Machine.board_millis
        handle_key(c)
      elsif !$ime || $ime.preedit.bytesize == 0
        idle_syntax_catchup
      end

      light_error = @session.light_error
      if light_error && light_error != @shown_light_error
        @shown_light_error = light_error
        @message = light_error
        draw_status
      end
      track_error = first_track_error
      if track_error != @shown_track_error
        @shown_track_error = track_error
        if track_error
          @message = track_error
          draw_status
        end
      end

      @view.draw
      @console.commit
      @view.note_loop_ms(Machine.board_millis - @loop_started_ms)
      sleep_ms 5
    end
  end

  # A statement that raises during staging is silenced per track and
  # its error recorded; without this readback the performer only sees
  # a dead track.
  def first_track_error
    scheduler = @session.scheduler
    names = scheduler.track_names
    i = 0
    while i < names.length
      name = names[i]
      i += 1
      error = scheduler.last_error(name)
      return "#{name}: #{error}" if error
    end
    nil
  end

  # -- Live eval --

  # One sandbox per eval. On the board a failed compile left the
  # resident sandbox erroring on every later eval even after the
  # buffer was fixed; a fresh task per eval carries no compiler or
  # task state across evals and takes the same first-run path that
  # app launching uses. Creation cost is one task, negligible next to
  # the eval itself.
  def new_eval_sandbox
    Sandbox.new("johakyu-live")
  end

  # -- Scenes (editor tabs) --

  # Write the viewport and file binding back to the current scene.
  # The buffer and undo arrays are shared objects mutated in place,
  # so they never need copying back.
  def store_scene
    scene = @scenes[@scene_index]
    scene.filepath = @filepath
    scene.scroll_top = @scroll_top
    scene.scroll_left = @scroll_left
  end

  # Scenes with unsaved changes, the current one included (its buffer
  # object is shared with its slot).
  def unsaved_scene_count
    count = 0
    i = 0
    while i < @scenes.length
      scene = @scenes[i]
      count += 1 if scene && scene.buffer.changed
      i += 1
    end
    count
  end

  # Switch to scene number 1..SCENE_COUNT. Scenes are created on
  # first visit; switching only swaps editor state, the running show
  # is untouched until the new buffer is applied.
  def switch_scene(number)
    index = number - 1
    return if index == @scene_index
    store_scene
    @scene_index = index
    scene = @scenes[index] ||= Scene.new
    @buffer = scene.buffer
    @filepath = scene.filepath
    @undo_stack = scene.undo_stack
    @redo_stack = scene.redo_stack
    @scroll_top = scene.scroll_top
    @scroll_left = scene.scroll_left
    @old_scroll_top = @scroll_top
    @old_scroll_left = @scroll_left
    @syntax = nil
    @buffer.mark_dirty(:structure)
    @message = "Scene #{number}"
  end

  def start_eval
    return if @evaling
    source = @buffer.lines.join("\n")
    # Build staged runway before the compile: mrc compile is one
    # atomic C call, so no tick can run inside it, and the sandbox
    # run that follows shares the CPU with the show loop. Pre-staged
    # pending events plus the reserve lead absorb both.
    @session.prestage
    @live.begin_recording
    compile_t0 = Machine.board_millis
    @sandbox.terminate if @sandbox
    @sandbox = new_eval_sandbox
    compiled = @sandbox.compile(source)
    @eval_compile_ms = Machine.board_millis - compile_t0
    if compiled
      @sandbox.execute
      @evaling = true
      @eval_started_ms = Machine.board_millis
      @message = "Evaluating..."
    else
      @live.discard
      @message = "Syntax error (buffer not applied)"
    end
    draw_status
  end

  def poll_eval
    return unless @evaling
    state = @sandbox.state
    if state == :DORMANT || state == :SUSPENDED
      @evaling = false
      error = @sandbox.error
      if error && !error.is_a?(SystemExit)
        @live.discard
        location = nil
        if error.respond_to?(:backtrace)
          backtrace = error.backtrace
          location = backtrace[0] if backtrace && backtrace.length > 0
        end
        if location
          @message = "#{location}: #{error.message} (#{error.class})"
        else
          @message = "#{error.message} (#{error.class})"
        end
      else
        patch_before = Johakyu.patch
        apply_t0 = Machine.board_millis
        @live.apply
        apply_ms = Machine.board_millis - apply_t0
        run_ms = apply_t0 - @eval_started_ms
        # Capture the lateness accumulated since the previous reset
        # before reset_stats wipes it: it covers this eval's compile
        # and run window, so it measures the eval stall at the output.
        late_count = @session.output_late_count
        late_ms = @session.output_late_ms_max
        # Restart the stats so tick/st/lt read as steady-state numbers
        # for the new binding, the same as the demo does per preset. A
        # cumulative average spanning an unmute keeps climbing toward
        # the new mean for minutes and reads like a slowdown.
        @session.reset_stats
        @view.reset_peaks
        @message = "Applied (compile #{@eval_compile_ms}ms, run #{run_ms}ms, apply #{apply_ms}ms, late #{late_count}/#{late_ms}ms)"
        unless Johakyu.patch.equal?(patch_before)
          # The rig changed: resize the universe view, re-lay the
          # editor out below it, and repaint everything.
          @view.repatch
          apply_layout
          @scroll_top = adjust_vertical_scroll
          redraw_screen
        end
      end
      draw_status
    elsif Machine.board_millis - @eval_started_ms > EVAL_TIMEOUT_MS
      # Do not stop a running task: the stop flag forces a return out
      # of a possibly nested mrb_vm_exec and hardfaults (the known
      # mruby-task nested-exec family). Terminate instead: it only
      # flips the task to DORMANT without unwinding it, so the
      # runaway script is dropped for good; the next eval brings its
      # own fresh sandbox.
      @sandbox.terminate
      @live.discard
      @evaling = false
      @message = "Eval timeout: scripts must not loop (bindings keep running)"
      draw_status
    end
  end

  # -- File I/O --

  # Replace the buffer content with text, split into lines; nil or an
  # empty string leaves a single empty line.
  def fill_buffer(content)
    @buffer.lines.clear
    if content
      content.split("\n").each { |l| @buffer.lines.push(l) }
    end
    @buffer.lines.push("") if @buffer.lines.empty?
  end

  def load_buffer
    content = nil
    if @filepath && File.exist?(@filepath)
      content = File.open(@filepath, "r") { |f| f.read }
    elsif File.file?(STARTER_PATH)
      content = File.open(STARTER_PATH, "r") { |f| f.read }
    end
    content = STARTER.join("\n") if content.nil?
    fill_buffer(content)
    @buffer.changed = false
  end

  # Save the buffer, asking for a path first when it is untitled.
  # Returns false when the prompt is cancelled or the write fails.
  def save_buffer
    unless @filepath
      path = prompt_input("Save as: ")
      draw_command_bar
      @buffer.mark_dirty(:structure)
      unless path && path.bytesize > 0
        @message = "Save cancelled"
        return false
      end
      @filepath = path
    end
    File.open(@filepath, "w") do |f|
      f.write(@buffer.lines.join("\n") + "\n")
    end
    @buffer.changed = false
    @message = "Saved #{@filepath}"
    true
  rescue => e
    @message = "Save failed: #{e.message}"
    false
  end

  # Open a file into the current scene, replacing its buffer. Asks
  # before discarding unsaved changes.
  def open_file
    if @buffer.changed
      answer = prompt_input("Discard unsaved changes? (y/n): ", y_or_n: true)
      draw_command_bar
      @buffer.mark_dirty(:structure)
      return unless answer && (answer == "y" || answer == "Y")
    end
    path = prompt_input("Open: ")
    draw_command_bar
    @buffer.mark_dirty(:structure)
    return unless path && path.bytesize > 0
    unless File.file?(path)
      @message = "No such file: #{path}"
      return
    end
    fill_buffer(File.open(path, "r") { |f| f.read })
    @buffer.move_to(0, 0)
    @scroll_top = 0
    @scroll_left = 0
    @undo_stack.clear
    @redo_stack.clear
    @buffer.changed = false
    @buffer.mark_dirty(:structure)
    @filepath = path
    @message = "Opened #{path}"
  end

  # -- Undo plumbing (same behavior as edit.rb) --

  def undo_record(entry)
    last = @undo_stack[-1]
    if last && entry[0] == :insert && last[0] == :insert &&
       entry[1] == last[1] && entry[2] == last[2] + last[3].bytesize
      last[3] += entry[3]
      return
    end
    if last && entry[0] == :delete && last[0] == :delete &&
       entry[1] == last[1] && entry[2] == last[2]
      last[3] += entry[3]
      return
    end
    if last && entry[0] == :delete && last[0] == :delete &&
       entry[1] == last[1] && entry[2] + entry[3].bytesize == last[2]
      last[2] = entry[2]
      last[3] = entry[3] + last[3]
      return
    end
    @undo_stack.push(entry)
    @undo_stack.shift if @undo_stack.length > UNDO_MAX
  end

  def undo_record_break
    @undo_stack.push(nil) if @undo_stack[-1] != nil && @undo_stack.length > 0
  end

  def apply_entry(entry)
    type, y, x, text = entry
    case type
    when :insert
      @buffer.move_to(x, y)
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s + text + line.byteslice(x, 65535).to_s
      @buffer.move_to(x + text.bytesize, y)
    when :delete
      @buffer.move_to(x, y)
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s + line.byteslice(x + text.bytesize, 65535).to_s
    when :split
      line = @buffer.lines[y]
      @buffer.lines[y] = line.byteslice(0, x).to_s
      @buffer.lines.insert(y + 1, line.byteslice(x, 65535).to_s)
      @buffer.move_to(0, y + 1)
    when :join
      @buffer.lines[y] = @buffer.lines[y] + @buffer.lines[y + 1]
      @buffer.lines.delete_at(y + 1)
      @buffer.move_to(x, y)
    end
    @buffer.mark_dirty(:structure)
    @buffer.changed = true
  end

  def reverse_type(type)
    case type
    when :insert then :delete
    when :delete then :insert
    when :split then :join
    when :join then :split
    end
  end

  def perform_undo
    @undo_stack.pop while @undo_stack[-1] == nil && @undo_stack.length > 0
    entry = @undo_stack.pop
    return false unless entry
    apply_entry([reverse_type(entry[0]), entry[1], entry[2], entry[3]])
    @redo_stack.push(entry)
    true
  end

  def perform_redo
    entry = @redo_stack.pop
    return false unless entry
    apply_entry(entry)
    @undo_stack.push(entry)
    true
  end

  # -- Syntax (windowed, same design as edit.rb) --

  # A line starting at column 0 with a top-level construct boundary is
  # a safe place to start parsing.
  def syntax_anchor?(line)
    return false if line.bytesize == 0
    b0 = line.getbyte(0)
    return false if b0 == 0x20 || b0 == 0x09
    return true if line == "end"
    line.start_with?("class ", "class\t", "module ", "module\t", "def ", "def\t")
  end

  def syntax_anchor_line(from_line)
    from_line = 0 if from_line < 0
    limit = from_line - SYNTAX_ANCHOR_SCAN
    limit = 0 if limit < 0
    i = from_line
    while i > limit
      line = @buffer.lines[i]
      return i if line && syntax_anchor?(line)
      i -= 1
    end
    limit
  end

  # Parse a window covering [top, bottom] plus margins, capped to the
  # analyzer byte budget. Pure: it does not touch the render window
  # state, so a small indent-only parse can run without clobbering the
  # cached highlight bundle. Returns [result, bundle, win_start,
  # win_end] where bundle is [highlight_map, offsets, win_start] (or
  # nil when parsing failed). margin_below can be 0 when only the
  # indent of a line is needed, since indentation depends only on the
  # lines above.
  def analyze_window(top, bottom, margin_below = SYNTAX_MARGIN)
    lines = @buffer.lines
    n = lines.length
    return [nil, nil, 0, 0] if n == 0
    top = 0 if top < 0
    bottom = n - 1 if bottom > n - 1
    bottom = top if bottom < top

    ws = syntax_anchor_line(top - SYNTAX_MARGIN)
    we = bottom + margin_below + 1
    we = n if we > n

    total = 0
    i = ws
    while i < we
      total += lines[i].bytesize + 1
      i += 1
    end
    while total > SYNTAX_MAX_BYTES && we > bottom + 1
      we -= 1
      total -= lines[we].bytesize + 1
    end
    while total > SYNTAX_MAX_BYTES && ws < top
      total -= lines[ws].bytesize + 1
      ws += 1
    end

    source = lines[ws...we].join("\n")
    result = RubySyntax.analyze(source)
    return [nil, nil, ws, we] unless result
    offsets = []
    off = 0
    i = ws
    while i < we
      offsets.push(off)
      off += lines[i].bytesize + 1
      i += 1
    end
    [result, [result.highlight_map, offsets, ws], ws, we]
  end

  # Rebuild the render highlight window for the current viewport and
  # store it in the cached bundle. Returns the raw result.
  def analyze_viewport
    t0 = Machine.board_millis
    result, bundle, ws, we = analyze_window(@scroll_top, @scroll_top + @edit_rows - 1)
    @syntax = bundle
    @win_start = ws
    @win_end = we
    @view.note_parse_ms(Machine.board_millis - t0) if @view
    result
  end

  # Byte slice of a bundle's highlight map covering one line, or nil
  # when the line is outside the bundle's window.
  def highlight_slice(bundle, line_index, line)
    return nil unless bundle
    rel = line_index - bundle[2]
    offsets = bundle[1]
    return nil if rel < 0 || rel >= offsets.length
    bundle[0].byteslice(offsets[rel], line.bytesize)
  end

  # Redraw only the visible lines whose highlight bytes differ between
  # the old and current bundle, so a recolor after a rebuild touches
  # the few lines that actually changed color instead of the whole
  # viewport. Returns true if anything was drawn.
  def sync_highlight_changes(first_row, last_row, skip_row, old_bundle)
    drawn = false
    row = first_row
    while row < last_row
      if row != skip_row
        line_index = @scroll_top + row
        line = @buffer.lines[line_index]
        if line && highlight_slice(old_bundle, line_index, line) != highlight_slice(@syntax, line_index, line)
          draw_line(row)
          drawn = true
        end
      end
      row += 1
    end
    drawn
  end

  # Deferred syntax work while the keyboard is idle. The reparse is
  # debounced (see SYNTAX_DEBOUNCE_MS) so an active edit never pays
  # the prism parse on the show loop, and the window is also rebuilt
  # ahead of time when the viewport nears its edge so a scroll does
  # not stall on a parse. Only the lines whose colors changed are
  # redrawn.
  def idle_syntax_catchup
    return unless @highlight_stale || near_window_edge?
    return if Machine.board_millis - @last_key_ms < SYNTAX_DEBOUNCE_MS
    sync_base = @highlight_stale ? @stale_syntax : @syntax
    @highlight_stale = false
    @prefetched_scroll_top = @scroll_top
    analyze_viewport
    @session.pump_outputs
    @console.hide_cursor
    redrawn = sync_highlight_changes(0, @edit_rows, -1, sync_base)
    place_cursor
    @console.commit if redrawn
  end

  def near_window_edge?
    return false if @scroll_top == @prefetched_scroll_top
    vis_bottom = @scroll_top + @edit_rows
    vis_bottom = @buffer.lines.length if vis_bottom > @buffer.lines.length
    (@win_start > 0 && @scroll_top - @win_start < SYNTAX_PREFETCH_MARGIN) ||
      (@win_end < @buffer.lines.length && @win_end - vis_bottom < SYNTAX_PREFETCH_MARGIN)
  end

  # -- Drawing --

  # Cursor movement redraws this row on every key (repeat runs at
  # 20 Hz), so it must stay allocation-light next to the audio fill:
  # no display_slice (it allocates one String per character).
  def draw_status
    line_num = @buffer.cursor_y + 1
    col_num = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) + 1
    modified = @buffer.changed ? " [+]" : ""
    name = @filepath || "[untitled]"
    status = " [#{@scene_index + 1}] #{name}#{modified}  #{line_num}:#{col_num}"
    status = " #{@message}" if @message
    width = Editor.display_width(status)
    if width < Console.cols
      status += " " * (Console.cols - width)
    elsif width > Console.cols
      status = Editor.display_slice(status, 0, Console.cols)
    end
    @console.put_string_at(0, @status_row, status, STATUS_ATTR)
  end

  # The bar text only changes with the IME mode label; cache the
  # padded string so per-key redraw is one put_string, no allocation.
  def draw_command_bar
    mode = $ime ? $ime.mode_label : nil
    if @command_bar_text.nil? || mode != @command_bar_mode
      @command_bar_mode = mode
      bar = " Alt-1..0:Scene  Ctrl-Enter:Eval  Ctrl-S:Save+Eval  Ctrl-O:Open  Ctrl-B:Blackout  Ctrl-Q:Quit"
      if mode
        padding = Console.cols - Editor.display_width(bar) - Editor.display_width(mode)
        bar += " " * padding if padding > 0
        bar += mode
      else
        padding = Console.cols - Editor.display_width(bar)
        bar += " " * padding if padding > 0
      end
      @command_bar_text = bar
    end
    @console.put_string_at(0, @command_row, @command_bar_text, COMMAND_ATTR)
  end

  # Prompt on the command bar. Keeps the show alive while waiting.
  def prompt_input(label, y_or_n: false)
    input = ""
    loop do
      display = " #{label}#{input}"
      padding = Console.cols - Editor.display_width(display)
      display += " " * padding if padding > 0
      @console.put_string_at(0, @command_row, Editor.display_slice(display, 0, Console.cols), COMMAND_ATTR)
      @console.commit

      c = @keyboard.read_char
      unless c
        # The prompt keeps the show alive; restarting the loop clock
        # here keeps the wait out of the lp stat (it is not a stall).
        @loop_started_ms = Machine.board_millis
        @session.update
        DMX.keepalive
        poll_eval
        @view.draw
        sleep_ms 5
        next
      end

      case c
      when Keyboard::ENTER
        return input
      when Keyboard::ESCAPE
        return nil
      when Keyboard::BSPACE
        if input.bytesize > 0
          input = input.byteslice(0, Editor.prev_char_byte_pos(input, input.bytesize))
        end
      else
        if c.printable?
          ch = c.to_s
          if y_or_n
            return ch if ch == "y" || ch == "Y" || ch == "n" || ch == "N"
          else
            input += ch
          end
        end
      end
    end
  end

  def draw_line(screen_row)
    row = @edit_top + screen_row
    line_index = @scroll_top + screen_row
    @console.clear_line(row)
    return if line_index >= @buffer.lines.length

    line = @buffer.lines[line_index]
    line_offset = nil
    if @syntax
      rel = line_index - @syntax[2]
      line_offset = @syntax[1][rel] if rel >= 0 && rel < @syntax[1].length
    end
    if line_offset
      RubySyntax.draw_line(0, row, line, @syntax[0], line_offset, @scroll_left, Console.cols, EDIT_ATTR)
    else
      text = Editor.display_slice(line, @scroll_left, Console.cols)
      @console.put_string_at(0, row, text, EDIT_ATTR) if text && text.bytesize > 0
    end
  end

  def draw_all_lines
    i = 0
    while i < @edit_rows
      draw_line(i)
      i += 1
    end
  end

  # Differential vertical scroll: shift with the DVI ring-buffer
  # scroll (O(1)) and draw only the newly exposed lines. The ring
  # scroll moves the whole screen, so the universe view, status row,
  # and command bar are repainted in the same frame.
  # Scroll the editor pane by copying its own rows. The global ring
  # scroll would shift the universe view rows along with the editor,
  # forcing a full view repaint per keystroke (every channel cell
  # flashed as changed, and the churn stalled the show loop).
  def scroll_view(vdelta)
    if vdelta > 0
      row = 0
      while row < @edit_rows - vdelta
        DVI::Text.write_line(@edit_top + row,
                             DVI::Text.read_line(@edit_top + row + vdelta))
        row += 1
      end
      row = @edit_rows - vdelta
      while row < @edit_rows
        draw_line(row)
        row += 1
      end
    else
      n = -vdelta
      row = @edit_rows - 1
      while row >= n
        DVI::Text.write_line(@edit_top + row,
                             DVI::Text.read_line(@edit_top + row - n))
        row -= 1
      end
      row = 0
      while row < n
        draw_line(row)
        row += 1
      end
    end
  end

  # Horizontal scroll has no ring-buffer shortcut; redraw the visible
  # lines whose content moved, skipping lines blank in both viewports.
  def draw_hscroll(old_scroll_left)
    threshold = old_scroll_left < @scroll_left ? old_scroll_left : @scroll_left
    i = 0
    while i < @edit_rows
      line = @buffer.lines[@scroll_top + i]
      if line.nil? || Editor.display_width(line) <= threshold
        i += 1
        next
      end
      draw_line(i)
      i += 1
    end
  end

  def place_cursor
    screen_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) - @scroll_left + @preedit_width
    screen_row = @edit_top + @buffer.cursor_y - @scroll_top
    @console.move_to(screen_col, screen_row)
    @console.show_cursor
  end

  # -- Scrolling --

  def adjust_vertical_scroll
    if @buffer.cursor_y < @scroll_top
      return @buffer.cursor_y
    end
    if @buffer.cursor_y >= @scroll_top + @edit_rows
      return @buffer.cursor_y - @edit_rows + 1
    end
    @scroll_top
  end

  # Jump-scroll horizontally (re-center) when the cursor leaves the
  # window, so per-column movement does not force full-width redraws.
  def adjust_horizontal_scroll
    line_width = Editor.display_width(@buffer.current_line)
    return 0 if line_width <= Console.cols
    cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x)
    if cursor_col >= @scroll_left && cursor_col < @scroll_left + Console.cols
      return @scroll_left
    end
    new_scroll = cursor_col - Console.cols / 2
    max_scroll = line_width - Console.cols + 1
    new_scroll = max_scroll if new_scroll > max_scroll
    new_scroll = 0 if new_scroll < 0
    new_scroll
  end

  # -- Key handling (edit.rb behavior + Ctrl-Enter/Ctrl-S eval) --

  def handle_key(c)
    @console.hide_cursor
    @message = nil
    @preedit_width = 0
    old_dirty = @buffer.dirty
    @old_scroll_top = @scroll_top
    @old_scroll_left = @scroll_left
    # Line index of a fresh split (Enter) or join (Backspace/Delete);
    # redraw_after_key shifts the rows below on screen instead of
    # repainting them all. Reset every key.
    @split_line = -1
    @join_line = -1
    @buffer.clear_dirty

    # Editor commands checked before the IME: an Alt+digit would
    # otherwise be fed into the preedit as a plain digit.
    if c.alt? && c.char && c.char >= "0" && c.char <= "9"
      $ime.reset if $ime
      switch_scene(c.char == "0" ? 10 : c.char.to_i)
      redraw_after_key(old_dirty)
      return
    end
    # Other Alt-modified keys are reserved for commands: ignore them
    # instead of feeding the IME or inserting their character (the
    # gem's printable? only excludes Ctrl).
    if c.alt?
      redraw_after_key(old_dirty)
      return
    end
    if c.match?(:o, ctrl: true)
      $ime.reset if $ime
      open_file
      redraw_after_key(old_dirty)
      return
    end
    if c.match?(:enter, ctrl: true)
      start_eval
      redraw_after_key(old_dirty)
      return
    end
    if c.match?(:b, ctrl: true)
      # Panic switch: zero the universe now. Bound light tracks keep
      # writing, so this darkens until their next event; eval an
      # empty buffer to silence for good.
      DMX.blackout
      @message = "Blackout (running tracks relight)"
      redraw_after_key(old_dirty)
      return
    end

    ime_handled = false
    if $ime
      ime_result = $ime.process(c)
      case ime_result
      when :commit
        text = $ime.take_committed
        @redo_stack.clear
        undo_record([:insert, @buffer.cursor_y, @buffer.cursor_x, text])
        @buffer.put(text)
        ime_handled = true
      when :consumed
        @buffer.mark_dirty(:content)
        ime_handled = true
      end
    end

    unless ime_handled
      case c
      when Keyboard::CTRL_Q, Keyboard::CTRL_C
        unsaved = unsaved_scene_count
        label = if unsaved == 0
          "Quit and blackout? (y/n): "
        elsif unsaved == 1
          "Quit and blackout? 1 scene unsaved (y/n): "
        else
          "Quit and blackout? #{unsaved} scenes unsaved (y/n): "
        end
        answer = prompt_input(label, y_or_n: true)
        draw_command_bar
        @buffer.mark_dirty(:structure)
        if answer && (answer == "y" || answer == "Y")
          @running = false
          return
        end
        @message = "Quit cancelled"
      when Keyboard::CTRL_S
        start_eval if save_buffer
      when Keyboard::CTRL_Z
        @message = "Undo" if perform_undo
      when Keyboard::CTRL_Y
        @message = "Redo" if perform_redo
      when Keyboard::PAGEUP
        @scroll_top -= @edit_rows
        @scroll_top = 0 if @scroll_top < 0
        @buffer.move_to(@buffer.cursor_x, @scroll_top)
      when Keyboard::PAGEDOWN
        max_scroll = @buffer.lines.length - @edit_rows
        max_scroll = 0 if max_scroll < 0
        @scroll_top += @edit_rows
        @scroll_top = max_scroll if @scroll_top > max_scroll
        new_y = @scroll_top + @edit_rows - 1
        new_y = @buffer.lines.length - 1 if new_y >= @buffer.lines.length
        @buffer.move_to(@buffer.cursor_x, new_y)
      when Keyboard::HOME
        undo_record_break
        @buffer.head
      when Keyboard::END_KEY
        undo_record_break
        @buffer.tail
      when Keyboard::DELETE
        @redo_stack.clear
        undo_record_break
        if @buffer.cursor_x >= @buffer.current_line.bytesize && @buffer.cursor_y + 1 < @buffer.lines.length
          undo_record([:join, @buffer.cursor_y, @buffer.cursor_x])
          @buffer.lines[@buffer.cursor_y] = @buffer.current_line + @buffer.lines[@buffer.cursor_y + 1]
          @buffer.lines.delete_at(@buffer.cursor_y + 1)
          @buffer.changed = true
          @buffer.mark_dirty(:structure)
          @join_line = @buffer.cursor_y
        else
          if @buffer.cursor_x < @buffer.current_line.bytesize
            deleted = Editor.char_at_bytepos(@buffer.current_line, @buffer.cursor_x)
            undo_record([:delete, @buffer.cursor_y, @buffer.cursor_x, deleted])
          end
          @buffer.delete
          @buffer.mark_dirty(:content)
        end
      when Keyboard::ENTER
        @redo_stack.clear
        undo_record([:split, @buffer.cursor_y, @buffer.cursor_x])
        undo_record_break
        @buffer.put(c.to_buffer_input)
        auto_indent
        @split_line = @buffer.cursor_y
      when Keyboard::BSPACE
        @redo_stack.clear
        if @buffer.cursor_x > 0
          prev_pos = Editor.prev_char_byte_pos(@buffer.current_line, @buffer.cursor_x)
          deleted = @buffer.current_line.byteslice(prev_pos, @buffer.cursor_x - prev_pos)
          undo_record([:delete, @buffer.cursor_y, prev_pos, deleted])
        elsif @buffer.cursor_y > 0
          undo_record_break
          undo_record([:join, @buffer.cursor_y - 1, @buffer.lines[@buffer.cursor_y - 1].bytesize])
          @join_line = @buffer.cursor_y - 1
        end
        @buffer.put(c.to_buffer_input)
      when Keyboard::UP, Keyboard::DOWN, Keyboard::LEFT, Keyboard::RIGHT
        undo_record_break
        @buffer.put(c.to_buffer_input)
      when Keyboard::ESCAPE
        # Ignore
      else
        if c.printable?
          @redo_stack.clear
          undo_record([:insert, @buffer.cursor_y, @buffer.cursor_x, c.to_s])
          @buffer.put(c.to_s)
          if c.to_s == " " && RubySyntax.should_dedent_on_space?(@buffer.current_line)
            result, _bundle, ws, _we = analyze_window(@buffer.cursor_y, @buffer.cursor_y, 0)
            @session.pump_outputs
            if result
              old_line = @buffer.current_line
              if RubySyntax.reindent_line(@buffer, @buffer.cursor_y, result.indent_level(@buffer.cursor_y - ws))
                undo_record([:replace_line, @buffer.cursor_y, old_line])
                @buffer.mark_dirty(:content)
              end
            end
          end
        else
          input = c.to_buffer_input
          @buffer.put(input) if input
        end
      end
    end

    redraw_after_key(old_dirty)
  end

  def auto_indent
    # Indentation depends only on the lines above, so parse with no
    # margin below the cursor (two lines, not the full window).
    result, _bundle, ws, _we = analyze_window(@buffer.cursor_y - 1, @buffer.cursor_y, 0)
    @session.pump_outputs
    return unless result
    prev_y = @buffer.cursor_y - 1
    if prev_y >= 0
      old_line = @buffer.lines[prev_y]
      if RubySyntax.reindent_line(@buffer, prev_y, result.indent_level(prev_y - ws))
        undo_record([:replace_line, prev_y, old_line])
      end
    end
    level = result.indent_level(@buffer.cursor_y - ws)
    if level > 0
      spaces = "  " * level
      undo_record([:insert, @buffer.cursor_y, 0, spaces])
      @buffer.put(spaces)
    end
  end

  def redraw_after_key(old_dirty)
    # Scrolling is a viewport change, not a buffer change: it does not
    # mark the buffer dirty and does not reparse. The differential
    # paths below redraw only what moved.
    @scroll_top = adjust_vertical_scroll
    @scroll_left = adjust_horizontal_scroll

    dirty = @buffer.dirty
    structure_changed = dirty == :structure
    content_changed = structure_changed || dirty == :content
    dirty = old_dirty if dirty == :none && old_dirty != :none
    vdelta = @scroll_top - @old_scroll_top
    hscrolled = @scroll_left != @old_scroll_left

    window_rebuilt = false
    vis_bottom = @scroll_top + @edit_rows
    vis_bottom = @buffer.lines.length if vis_bottom > @buffer.lines.length

    # A single-line split (Enter) or join (Backspace/Delete) that did
    # not scroll the viewport shifts the rows below on screen and
    # redraws only the touched lines, so its reparse is deferred to an
    # idle frame like a content edit: the shift keeps every other line
    # correct and only two lines briefly carry stale colors.
    can_shift = !hscrolled && vdelta == 0 &&
                (@split_line >= 0 || @join_line >= 0) &&
                @scroll_top >= @win_start && vis_bottom <= @win_end

    # A content edit or a shift-eligible split/join defers its reparse
    # to a debounced idle catch-up: the parse is an atomic prism call
    # that would stall the show loop on every keystroke otherwise. A
    # structure edit that scrolled or left the window must parse now
    # (offsets shifted and the viewport moved), then pump what came due.
    sync_base = nil
    if (structure_changed && !can_shift) || @scroll_top < @win_start || vis_bottom > @win_end
      sync_base = @highlight_stale ? @stale_syntax : @syntax
      analyze_viewport
      @session.pump_outputs
      window_rebuilt = true
      @highlight_stale = false
    elsif content_changed
      @stale_syntax = @syntax unless @highlight_stale
      @highlight_stale = true
    end

    if @split_line >= 0 && can_shift
      # Shift the rows below the split down one, then draw the
      # truncated original line and the new line.
      split_row = @split_line - @scroll_top
      row = @edit_rows - 1
      while row > split_row
        DVI::Text.write_line(@edit_top + row, DVI::Text.read_line(@edit_top + row - 1))
        row -= 1
      end
      draw_line(split_row - 1) if split_row > 0
      draw_line(split_row)
    elsif @join_line >= 0 && can_shift
      # Shift the rows below the join up one, draw the newly exposed
      # bottom row and the merged line.
      join_row = @join_line - @scroll_top
      row = join_row + 1
      while row < @edit_rows - 1
        DVI::Text.write_line(@edit_top + row, DVI::Text.read_line(@edit_top + row + 1))
        row += 1
      end
      draw_line(@edit_rows - 1) if join_row < @edit_rows - 1
      draw_line(join_row)
    elsif dirty == :structure || vdelta.abs >= @edit_rows ||
          (hscrolled && vdelta != 0) || (window_rebuilt && !content_changed)
      draw_all_lines
    elsif hscrolled
      draw_hscroll(@old_scroll_left)
    else
      cursor_row = dirty == :content ? @buffer.cursor_y - @scroll_top : -1
      scroll_view(vdelta) if vdelta != 0
      # After a synchronous rebuild, redraw only the lines whose colors
      # changed. Rows exposed by scroll_view and the cursor row are
      # drawn separately below.
      if window_rebuilt
        first_row = vdelta < 0 ? -vdelta : 0
        last_row = vdelta > 0 ? @edit_rows - vdelta : @edit_rows
        sync_highlight_changes(first_row, last_row, cursor_row, sync_base)
      end
      draw_line(cursor_row) if cursor_row >= 0
    end

    draw_status

    @preedit_width = 0
    if $ime && $ime.preedit.bytesize > 0
      cursor_col = Editor.byte_to_display_col(@buffer.current_line, @buffer.cursor_x) - @scroll_left
      preedit_row = @edit_top + @buffer.cursor_y - @scroll_top
      if preedit_row >= @edit_top && preedit_row <= @edit_bottom
        max_preedit = Console.cols - cursor_col
        if max_preedit > 0
          visible = Editor.display_slice($ime.preedit, 0, max_preedit)
          if visible && visible.bytesize > 0
            DVI::Text.put_string(cursor_col, preedit_row, visible, InputMethod::PREEDIT_ATTR)
            @preedit_width = Editor.display_width(visible)
          end
        end
      end
    end

    if $ime && $ime.candidates
      cand_text = ""
      ci = 0
      $ime.candidates.each do |cand|
        break if ci >= 7
        cand_text += " " if ci > 0
        cand_text += "#{ci + 1}:#{cand}"
        ci += 1
      end
      mode = $ime.mode_label
      if mode
        padding = Console.cols - Editor.display_width(cand_text) - Editor.display_width(mode)
        cand_text += " " * padding if padding > 0
        cand_text += mode
      else
        padding = Console.cols - Editor.display_width(cand_text)
        cand_text += " " * padding if padding > 0
      end
      @console.put_string_at(0, @command_row, Editor.display_slice(cand_text, 0, Console.cols), COMMAND_ATTR)
    else
      draw_command_bar
    end

    place_cursor
  end
end

JohakyuApp.new(ARGV[0]).run
