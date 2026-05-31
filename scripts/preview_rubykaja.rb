#!/usr/bin/env ruby
# frozen_string_literal: true

# Desktop browser preview for rubykaja.rb.
#
# Generates a self-contained HTML that runs rootfs/app/rubykaja.rb in the
# browser via picoruby.wasm (the same mruby VM the Harucom Board uses), with
# a Canvas-backed P5 shim, a Keyboard shim that mirrors the device's
# Keyboard::Key API, and a Machine.board_millis shim.
#
# Usage:
#   ruby scripts/preview_rubykaja.rb [output.html]
#   # default output: build/preview_rubykaja.html
# Open the produced HTML in any modern browser.

require "fileutils"

APP_PATH = File.expand_path("../rootfs/app/rubykaja.rb", __dir__)
OUTPUT_PATH = ARGV[0] || File.expand_path("../build/preview_rubykaja.html", __dir__)

raw = File.read(APP_PATH)

# Strip the device-only `require "p5"` since the shim defines P5 inline.
app_source = raw.sub(/^require "p5"\n/, "")

FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))

# Picoruby shim. Defines just enough of DVI / Machine / Keyboard / P5 to
# let rubykaja run unmodified in the browser. P5 is backed by a 2D Canvas;
# sprites are backed by offscreen Canvases so #blit / #image work.
shim_source = <<~'RUBY'
  require "js"

  # picoruby tasks do not get ARGV defined automatically; rubykaja reads
  # ARGV[0] to pick the initial timer length, so seed it from the page URL
  # (?seconds=NN) or default to "150".
  argv_secs = "150"
  query = JS.global[:location][:search].to_s
  if query.include?("seconds=")
    parsed = query.sub(/.*seconds=/, "").sub(/&.*/, "")
    argv_secs = parsed unless parsed.empty?
  end
  Object.const_set(:ARGV, [argv_secs])

  # ----- DVI shim -----
  module DVI
    GRAPHICS_MODE = :graphics
    TEXT_MODE     = :text

    def self.set_mode(mode); end

    module Graphics
      FONT_8X8        = [:monospace,  8]
      FONT_MPLUS_12   = [:sans_serif, 10]
      FONT_MPLUS_J12  = [:sans_serif, 10]

      @@logical_w = 320
      @@logical_h = 240

      def self.set_resolution(w, h)
        @@logical_w = w
        @@logical_h = h
      end

      def self.width;  @@logical_w; end
      def self.height; @@logical_h; end
      def self.font_height(font); font[1]; end
      def self.commit; end

      # Used by P5#blit and the *_to helpers. Sprite buffers are stored
      # as offscreen Canvases (HTMLCanvasElement) wrapped in JS::Object.
      def self.blit(buf, x, y, w, h, transparent)
        P5.instance.blit_canvas(buf, x, y, w, h, transparent)
      end

      def self.fill_rect_to(buf, bw, bh, x, y, w, h, color)
        P5.instance.fill_rect_on(buf, bw, bh, x, y, w, h, color)
      end

      def self.fill_circle_to(buf, bw, bh, cx, cy, r, color)
        P5.instance.fill_circle_on(buf, bw, bh, cx, cy, r, color)
      end

      def self.fill_triangle_to(buf, bw, bh, x0, y0, x1, y1, x2, y2, color)
        P5.instance.fill_triangle_on(buf, bw, bh, x0, y0, x1, y1, x2, y2, color)
      end

      def self.draw_line_to(buf, bw, bh, x0, y0, x1, y1, color)
        P5.instance.draw_line_on(buf, bw, bh, x0, y0, x1, y1, color)
      end
    end
  end

  # ----- Machine timer shim -----
  module Machine
    def self.board_millis
      JS.global[:performance].now.to_f.to_i
    end
  end

  # sleep_ms uses Ruby's sleep (seconds); picoruby's scheduler yields to
  # JS naturally, so the canvas + keyboard event loop keeps working.
  def sleep_ms(ms)
    return if ms <= 0
    sleep(ms / 1000.0)
  end

  # ----- Keyboard shim -----
  # Mirrors the device's Keyboard::Key API so rubykaja's drain_input can
  # match `Keyboard::CTRL_C` / `Keyboard::ESCAPE` and read `key.char`.
  module Keyboard
    class Key
      attr_reader :char, :name
      def initialize(char, name = nil, ctrl: false)
        @char = char
        @name = name
        @ctrl = ctrl
      end
      def ctrl?; @ctrl; end
    end

    ENTER  = Key.new(nil, :enter)
    ESCAPE = Key.new(nil, :escape)
    CTRL_C = Key.new(nil, :c, ctrl: true)
  end

  class KeyboardShim
    def initialize
      @queue = []
    end

    # Called from JS keydown handler. Maps a JS key to a Keyboard::Key
    # instance (constants are reused so `case/when` identity matches).
    def push(label)
      key = case label
            when "ENTER"  then Keyboard::ENTER
            when "ESCAPE" then Keyboard::ESCAPE
            when "CTRL_C" then Keyboard::CTRL_C
            else
              Keyboard::Key.new(label) if label && !label.empty?
            end
      @queue << key if key
    end

    def read_char
      @queue.shift
    end
  end

  $keyboard = KeyboardShim.new

  # Bridge browser keydown events directly from the Ruby task. picoruby's
  # JS interop can't store a Ruby object as a JS property, so we instead
  # add the listener here and translate event.key into a label the Ruby
  # KeyboardShim understands.
  JS.global[:document].addEventListener("keydown") do |event|
    key = event[:key].to_s
    label = case key
            when "Enter"  then "ENTER"
            when "Escape" then "ESCAPE"
            when " "      then " "
            else
              if event[:ctrlKey].to_s == "true" && (key == "c" || key == "C")
                "CTRL_C"
              elsif key.length == 1
                key
              end
            end
    $keyboard.push(label) if label
    # preventDefault for game keys is handled synchronously by a JS-side
    # listener; calling it here is too late because picoruby dispatches
    # this callback as a scheduled task after the browser default fires.
  end

  # ----- P5 (Canvas-backed) -----
  # Mirrors the device P5 surface area used by rubykaja. Sprites built via
  # create_graphics are offscreen Canvases; #blit composites them onto the
  # main canvas with optional color-key transparency.
  class P5
    G = DVI::Graphics

    @@instance = nil
    def self.instance; @@instance; end

    def initialize
      @canvas = JS.global[:document].getElementById("p5_canvas")
      @ctx = @canvas.getContext("2d")
      @width  = G.width
      @height = G.height
      reset_state
      @target_buf = nil
      @target_w = @width
      @target_h = @height
      @data = nil
      @@instance = self
    end

    private def reset_state
      @fill_color = "#ffffff"
      @fill_enabled = true
      @stroke_color = "#ffffff"
      @stroke_enabled = true
      @stroke_weight = 1
      @text_font = [:sans_serif, 10]
      @text_color = "#ffffff"
      @text_align_h = "left"
      @text_align_v = "top"
      @translate_only = true
      @matrix_tx = 0
      @matrix_ty = 0
    end

    # Create an offscreen P5 surface backed by a Canvas of the requested
    # size. Drawing methods route to this canvas when @target_buf is set.
    def self.create_graphics(w, h)
      sprite = P5.allocate
      sprite.send(:init_sprite, w, h)
      sprite
    end

    def create_graphics(w, h)
      P5.create_graphics(w, h)
    end

    private def init_sprite(w, h)
      reset_state
      doc = JS.global[:document]
      off = doc.createElement("canvas")
      off[:width] = w
      off[:height] = h
      @sprite_canvas = off
      @ctx = off.getContext("2d")
      @target_buf = off
      @target_w = w
      @target_h = h
      @width = w
      @height = h
      @data = [off, w, h]
    end

    attr_reader :target_buf, :target_w, :target_h, :data
    def width;  @width;  end
    def height; @height; end

    # State setters

    def fill(c)
      @fill_color = rgb332_to_css(c)
      @fill_enabled = true
    end

    def no_fill;  @fill_enabled = false; end

    def stroke(c)
      @stroke_color = rgb332_to_css(c)
      @stroke_enabled = true
    end

    def no_stroke; @stroke_enabled = false; end

    def stroke_weight(w); @stroke_weight = w; end

    def text_font(font, _wide = nil); @text_font = font; end
    def text_color(c); @text_color = rgb332_to_css(c); end

    def text_align(h, v = :top)
      @text_align_h = h.to_s
      @text_align_v = case v
                      when :top    then "top"
                      when :center then "middle"
                      when :bottom then "bottom"
                      else "top"
                      end
    end

    def text_leading(_pixels); end

    def text_width(str)
      apply_font
      @ctx.measureText(str.to_s)[:width].to_f.to_i
    end

    # Matrix / blend (no-ops or simple implementations)

    # TRANS_KEY (magenta) is used by the device as a color-key transparent
    # background for sprites. On Canvas we just clear the bitmap to
    # transparent pixels; drawImage then composites natively without the
    # anti-aliased magenta fringe that a color-key approach would leave.
    def background(c)
      if c.to_i == 0xE3
        @ctx.clearRect(0, 0, @width, @height)
      else
        @ctx[:fillStyle] = rgb332_to_css(c)
        @ctx.fillRect(0, 0, @width, @height)
      end
    end

    def commit
      # Picoruby yields between tasks during sleep; nothing extra needed
      # for the main canvas. Sprite targets never commit.
    end

    def blend_mode(_); end
    def alpha(_); end

    # Forward matrix transforms to the canvas so draw_big_centered's
    # translate/scale dance for the countdown / START / GOAL / BOOM banners
    # actually scales the text instead of dropping the call.
    def push_matrix; @ctx.save; end
    def pop_matrix;  @ctx.restore; end
    def translate(tx, ty); @ctx.translate(tx, ty); end
    def rotate(angle);     @ctx.rotate(angle); end
    def scale(sx, sy = nil)
      sy = sx if sy.nil?
      @ctx.scale(sx, sy)
    end
    def reset_matrix; @ctx.setTransform(1, 0, 0, 1, 0, 0); end

    # Shape drawing

    def point(x, y)
      return unless @stroke_enabled
      @ctx[:fillStyle] = @stroke_color
      @ctx.fillRect(x, y, 1, 1)
    end

    def line(x0, y0, x1, y1)
      return unless @stroke_enabled
      @ctx[:strokeStyle] = @stroke_color
      @ctx[:lineWidth] = @stroke_weight
      @ctx.beginPath
      @ctx.moveTo(x0 + 0.5, y0 + 0.5)
      @ctx.lineTo(x1 + 0.5, y1 + 0.5)
      @ctx.stroke
    end

    def rect(x, y, w, h)
      if @fill_enabled
        @ctx[:fillStyle] = @fill_color
        @ctx.fillRect(x, y, w, h)
      end
      if @stroke_enabled
        @ctx[:strokeStyle] = @stroke_color
        @ctx[:lineWidth] = @stroke_weight
        @ctx.strokeRect(x + 0.5, y + 0.5, w, h)
      end
    end

    def circle(cx, cy, r)
      @ctx.beginPath
      @ctx.arc(cx, cy, r, 0, 6.283185307179586)
      @ctx.fill if @fill_enabled && (apply_fill; true)
      @ctx.stroke if @stroke_enabled && (apply_stroke; true)
    end

    def ellipse(cx, cy, rx, ry)
      @ctx.beginPath
      @ctx.ellipse(cx, cy, rx, ry, 0, 0, 6.283185307179586)
      @ctx.fill if @fill_enabled && (apply_fill; true)
      @ctx.stroke if @stroke_enabled && (apply_stroke; true)
    end

    def triangle(x0, y0, x1, y1, x2, y2)
      @ctx.beginPath
      @ctx.moveTo(x0, y0)
      @ctx.lineTo(x1, y1)
      @ctx.lineTo(x2, y2)
      @ctx.closePath
      @ctx.fill if @fill_enabled && (apply_fill; true)
      @ctx.stroke if @stroke_enabled && (apply_stroke; true)
    end

    def arc(cx, cy, r, start_angle, stop_angle)
      @ctx.beginPath
      @ctx.arc(cx, cy, r, start_angle, stop_angle)
      @ctx.fill if @fill_enabled && (apply_fill; true)
      @ctx.stroke if @stroke_enabled && (apply_stroke; true)
    end

    # Image / blit

    # Two-mode image: P5 sprite => blit, raw buffer => not supported in
    # the preview (rubykaja doesn't use the raw path).
    def image(arg, x, y, w_or_transparent = nil, _h = nil)
      return unless arg.is_a?(P5)
      d = arg.data
      transparent = w_or_transparent || -1
      blit_canvas(d[0], x, y, d[1], d[2], transparent)
    end

    # Fast blit used by the device's optimized rubykaja code. Sprite buffers
    # are offscreen Canvases; transparent < 0 = opaque copy, otherwise we
    # treat magenta (TRANS_KEY = 0xE3) as transparent.
    def blit(sprite, x, y, transparent = -1)
      d = sprite.data
      blit_canvas(d[0], x, y, d[1], d[2], transparent)
    end

    # Routed-from-DVI helper. The sprite buffer is the offscreen Canvas.
    # Sprites built with background(TRANS_KEY) already start fully clear
    # on the alpha channel, so drawImage handles transparency for us; the
    # `transparent` arg is ignored on the canvas path.
    def blit_canvas(canvas, x, y, _w, _h, _transparent)
      @ctx.drawImage(canvas, x, y)
    end

    def fill_rect_on(buf, _bw, _bh, x, y, w, h, color)
      ctx = buf.getContext("2d")
      ctx[:fillStyle] = rgb332_to_css(color)
      ctx.fillRect(x, y, w, h)
    end

    def fill_circle_on(buf, _bw, _bh, cx, cy, r, color)
      ctx = buf.getContext("2d")
      ctx[:fillStyle] = rgb332_to_css(color)
      ctx.beginPath
      ctx.arc(cx, cy, r, 0, 6.283185307179586)
      ctx.fill
    end

    def fill_triangle_on(buf, _bw, _bh, x0, y0, x1, y1, x2, y2, color)
      ctx = buf.getContext("2d")
      ctx[:fillStyle] = rgb332_to_css(color)
      ctx.beginPath
      ctx.moveTo(x0, y0)
      ctx.lineTo(x1, y1)
      ctx.lineTo(x2, y2)
      ctx.closePath
      ctx.fill
    end

    def draw_line_on(buf, _bw, _bh, x0, y0, x1, y1, color)
      ctx = buf.getContext("2d")
      ctx[:strokeStyle] = rgb332_to_css(color)
      ctx[:lineWidth] = 1
      ctx.beginPath
      ctx.moveTo(x0 + 0.5, y0 + 0.5)
      ctx.lineTo(x1 + 0.5, y1 + 0.5)
      ctx.stroke
    end

    def set_pixel(x, y, c)
      @ctx[:fillStyle] = rgb332_to_css(c)
      @ctx.fillRect(x, y, 1, 1)
    end

    def text(str, x, y)
      apply_font
      @ctx[:fillStyle] = @text_color
      @ctx[:textAlign] = @text_align_h
      @ctx[:textBaseline] = @text_align_v
      @ctx.fillText(str.to_s, x, y)
    end

    def color(r, g, b)
      (r.to_i & 0xE0) | ((g.to_i >> 3) & 0x1C) | ((b.to_i >> 6) & 0x03)
    end

    private

    def apply_fill;    @ctx[:fillStyle] = @fill_color; end
    def apply_stroke
      @ctx[:strokeStyle] = @stroke_color
      @ctx[:lineWidth] = @stroke_weight
    end

    def apply_font
      name = case @text_font[0]
             when :monospace then "monospace"
             else "sans-serif"
             end
      @ctx[:font] = "#{@text_font[1]}px #{name}"
    end

    def rgb332_to_css(val)
      v = val.to_i & 0xFF
      r = ((v >> 5) & 0x7) * 255 / 7
      g = ((v >> 2) & 0x7) * 255 / 7
      b = (v & 0x3) * 255 / 3
      "rgb(#{r},#{g},#{b})"
    end

  end
RUBY

# Build the page. Both shim and app source live in one Ruby task so that
# constants are defined before rubykaja references them.
html = <<~HTML
  <!DOCTYPE html>
  <html lang="ja">
  <head>
    <meta charset="utf-8">
    <title>RubyKaja Special Award Timer</title>
    <style>
      body {
        background: #111;
        color: #ddd;
        font-family: Helvetica, Arial, sans-serif;
        margin: 0;
        padding: 20px;
        text-align: center;
      }
      h1 { margin: 0 0 8px; font-size: 18px; color: #ffcc66; }
      p  { margin: 4px 0; font-size: 12px; color: #999; }
      canvas#p5_canvas {
        display: block;
        margin: 12px auto;
        background: #000;
        border: 1px solid #333;
        image-rendering: pixelated;
        image-rendering: crisp-edges;
        width: 640px;
        height: 480px;
      }
      .status { color: #666; font-size: 11px; }
      kbd { background: #333; color: #fff; padding: 1px 5px; border-radius: 3px; font-family: monospace; }
    </style>
  </head>
  <body>
    <h1>Congrats on the RubyKaja 2026 Special Award, makicamel.</h1>
    <p>
      <kbd>Space</kbd> start / restart &nbsp;|&nbsp;
      <kbd>1</kbd>/<kbd>2</kbd>/<kbd>3</kbd> timer (150 / 60 / 30 s) &nbsp;|&nbsp;
      <kbd>Esc</kbd> quit
    </p>
    <p class="status">Click the canvas to focus, then press a key. Powered by picoruby.wasm.</p>
    <canvas id="p5_canvas" width="320" height="240" tabindex="0"></canvas>
    <p class="status" id="status">Loading picoruby.wasm...</p>

    <script type="text/ruby">
  #{shim_source.chomp}

      # ===== rubykaja app code (embedded) =====
  #{app_source.chomp}
    </script>

    <script>
      // Synchronously preventDefault for game keys so the browser does not
      // scroll on Space / arrows etc. The Ruby task that queues the key
      // for rubykaja runs asynchronously, which is too late to cancel the
      // default action; this listener fires first and stops it.
      const SWALLOW = new Set([
        " ", "Enter", "Escape", "Tab", "Backspace",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"
      ]);
      window.addEventListener("keydown", (evt) => {
        if (SWALLOW.has(evt.key)) evt.preventDefault();
      }, { capture: true });

      window.addEventListener("load", () => {
        document.getElementById("p5_canvas").focus();
        document.getElementById("status").textContent = "Running.";
      });
    </script>

    <script src="https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@3.4.5/dist/init.iife.js"></script>
  </body>
  </html>
HTML

File.write(OUTPUT_PATH, html)
puts "Wrote #{OUTPUT_PATH}"
