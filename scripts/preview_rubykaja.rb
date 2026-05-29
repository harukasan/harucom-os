#!/usr/bin/env ruby
# frozen_string_literal: true

# Desktop browser preview for rubykaja.rb.
#
# Generates a self-contained HTML that runs rootfs/app/rubykaja.rb via
# ruby.wasm with a Canvas-backed P5 shim, Keyboard shim, Machine.board_millis
# shim, and a no-op Board::PWMAudio shim (audio is muted on desktop).
#
# Usage:
#   ruby scripts/preview_rubykaja.rb [output.html]
#   # default output: build/preview_rubykaja.html
# Open the produced HTML in any modern browser.

require "fileutils"

APP_PATH = File.expand_path("../rootfs/app/rubykaja.rb", __dir__)
OUTPUT_PATH = ARGV[0] || File.expand_path("../build/preview_rubykaja.html", __dir__)

raw = File.read(APP_PATH)

# Strip require/begin-rescue lines that reference device-only libraries.
# Browser shim pre-defines P5, DVI, Machine, Keyboard, Board::PWMAudio.
sanitized = raw.dup
sanitized.sub!(/^require "p5"\n/, "")
sanitized.sub!(/^begin\n\s*require "board\/pwm_audio"\nrescue\nend\n/, "")

# Also strip the runtime defined?(Board::PWMAudio) branch; shim always provides it.
# Leave the code as-is otherwise.

FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>RubyKaja Preview</title>
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
        /* upscale the 320x240 backing buffer to 640x480 on screen with crisp edges */
        width: 320px;
        height: 240px;
      }
      .status { color: #666; font-size: 11px; }
    </style>
  </head>
  <body>
    <h1>RubyKaja celebration preview</h1>
    <p>Enter = start / goal / restart &nbsp; | &nbsp; Esc = quit</p>
    <p>Audio is muted on desktop preview. Add <code>?seconds=30</code> to URL to change timer.</p>
    <canvas id="p5_canvas" width="320" height="240" tabindex="0"></canvas>
    <p class="status" id="status">Loading ruby.wasm...</p>

    <script type="module">
    import { DefaultRubyVM } from "https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.8.1/dist/browser/+esm";

    const APP_CODE = #{sanitized.dump};

    const SHIM_CODE = String.raw`
      require "js"

      # ----- DVI shim -----
      module DVI
        GRAPHICS_MODE = :graphics
        TEXT_MODE     = :text

        def self.set_mode(mode); end
        def self.frame_count; 0; end

        module Graphics
          FONT_8X8         = ["monospace",   8]
          FONT_MPLUS_12    = ["sans-serif", 10]
          FONT_MPLUS_J12   = ["sans-serif", 10]
          FONT_FIXED_5X7   = ["monospace",   7]
          FONT_SPLEEN_8X16 = ["monospace",  12]
          FONT_HELVETICA_18      = ["sans-serif", 14]
          FONT_HELVETICA_BOLD_18 = ["sans-serif", 14]
          FONT_HELVETICA_BOLD_24 = ["sans-serif", 18]

          @@logical_w = 320
          @@logical_h = 240

          def self.set_resolution(w, h)
            @@logical_w = w
            @@logical_h = h
            P5.set_logical(w, h)
          end

          def self.width;  @@logical_w; end
          def self.height; @@logical_h; end

          def self.font_height(font); font[1]; end
        end
      end

      # ----- Machine timer shim -----
      module Machine
        def self.board_millis
          JS.global[:performance].now.to_f.to_i
        end

        def self.uptime_us
          (JS.global[:performance].now.to_f * 1000).to_i
        end
      end

      def sleep_ms(ms); end

      # ----- Keyboard shim -----
      module Keyboard
        ENTER  = "\\r"
        ESCAPE = "\\e"
        CTRL_C = "\\x03"
        CTRL_D = "\\x04"
        TAB    = "\\t"
        BSPACE = "\\b"
        UP     = "\\x1bUP"
        DOWN   = "\\x1bDOWN"
        LEFT   = "\\x1bLEFT"
        RIGHT  = "\\x1bRIGHT"
      end

      class KeyboardShim
        def initialize
          @queue = []
        end

        def push(code)
          @queue << code if code && !code.empty?
        end

        def read_char
          @queue.shift
        end
      end

      $keyboard = KeyboardShim.new

      # ----- Board::PWMAudio (no-op) -----
      module Board
        class PWMAudio
          SQUARE = 0; SINE = 1; TRIANGLE = 2; SAWTOOTH = 3
          C4 = 262; CS4 = 277; D4 = 294; DS4 = 311
          E4 = 330; F4 = 349; FS4 = 370; G4 = 392
          GS4 = 415; A4 = 440; AS4 = 466; B4 = 494
          C5 = 523; D5 = 587; E5 = 659; G5 = 784
          A5 = 880; C6 = 1047

          def initialize(*); end
          def tone(*, **); end
          def pan(*); end
          def mute(*); end
          def stop(*); end
          def stop_all; end
          def update; end
          def beep(*, **); end
          def deinit; end
        end
      end

      # ----- P5 (Canvas-backed) -----
      class P5
        G = DVI::Graphics

        REPLACE  = :replace
        ADD      = :add
        SUBTRACT = :subtract
        MULTIPLY = :multiply
        SCREEN   = :screen

        @@instance = nil

        def self.set_logical(w, h)
          @@instance.set_logical(w, h) if @@instance
        end

        def initialize
          @canvas = JS.global[:document].getElementById("p5_canvas")
          @ctx = @canvas.getContext("2d")
          @width  = G.width
          @height = G.height
          @ctx.setTransform(1, 0, 0, 1, 0, 0)
          @fill_color = "#ffffff"
          @fill_enabled = true
          @stroke_color = "#ffffff"
          @stroke_enabled = true
          @stroke_weight = 1
          @text_font = ["sans-serif", 10]
          @text_color = "#ffffff"
          @text_align_h = "left"
          @text_align_v = "top"
          @text_leading = 0
          @@instance = self
        end

        def set_logical(w, h)
          @width  = w
          @height = h
          @ctx.setTransform(1, 0, 0, 1, 0, 0)
        end

        def width;  @width;  end
        def height; @height; end

        def background(c)
          @ctx.setTransform(1, 0, 0, 1, 0, 0)
          css = rgb332_to_css(c)
          @ctx[:fillStyle] = css
          @ctx.fillRect(0, 0, @width, @height)
        end

        def commit
          Fiber.yield
        rescue FiberError
          # not running inside a fiber (e.g. static slide preview); no-op.
        end

        def fill(c)
          @fill_color = rgb332_to_css(c)
          @fill_enabled = true
        end

        def no_fill
          @fill_enabled = false
        end

        def stroke(c)
          @stroke_color = rgb332_to_css(c)
          @stroke_enabled = true
        end

        def no_stroke
          @stroke_enabled = false
        end

        def stroke_weight(w)
          @stroke_weight = w
          @ctx[:lineWidth] = w
        end

        def blend_mode(_); end
        def alpha(_); end

        def text_font(font, _wide = nil)
          @text_font = font
          name, size = font
          @ctx[:font] = "\#{size}px \#{name}"
        end

        def text_color(c)
          @text_color = rgb332_to_css(c)
        end

        def text_align(h, v = :top)
          @text_align_h = h.to_s
          @text_align_v = case v
                          when :top    then "top"
                          when :center then "middle"
                          when :bottom then "bottom"
                          else "top"
                          end
        end

        def text_leading(pixels)
          @text_leading = pixels
        end

        def text_width(str)
          @ctx[:font] = "\#{@text_font[1]}px \#{@text_font[0]}"
          @ctx.measureText(str.to_s)[:width].to_f.to_i
        end

        def push_matrix
          @ctx.save
        end

        def pop_matrix
          @ctx.restore
        end

        def translate(tx, ty)
          @ctx.translate(tx, ty)
        end

        def rotate(angle)
          @ctx.rotate(angle)
        end

        def scale(sx, sy = nil)
          sy = sx if sy.nil?
          @ctx.scale(sx, sy)
        end

        def reset_matrix
          @ctx.setTransform(1, 0, 0, 1, 0, 0)
        end

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
          @ctx.arc(cx, cy, r, 0, 2 * Math::PI)
          if @fill_enabled
            @ctx[:fillStyle] = @fill_color
            @ctx.fill
          end
          if @stroke_enabled
            @ctx[:strokeStyle] = @stroke_color
            @ctx[:lineWidth] = @stroke_weight
            @ctx.stroke
          end
        end

        def ellipse(cx, cy, rx, ry)
          @ctx.beginPath
          @ctx.ellipse(cx, cy, rx, ry, 0, 0, 2 * Math::PI)
          if @fill_enabled
            @ctx[:fillStyle] = @fill_color
            @ctx.fill
          end
          if @stroke_enabled
            @ctx[:strokeStyle] = @stroke_color
            @ctx[:lineWidth] = @stroke_weight
            @ctx.stroke
          end
        end

        def triangle(x0, y0, x1, y1, x2, y2)
          @ctx.beginPath
          @ctx.moveTo(x0, y0)
          @ctx.lineTo(x1, y1)
          @ctx.lineTo(x2, y2)
          @ctx.closePath
          if @fill_enabled
            @ctx[:fillStyle] = @fill_color
            @ctx.fill
          end
          if @stroke_enabled
            @ctx[:strokeStyle] = @stroke_color
            @ctx[:lineWidth] = @stroke_weight
            @ctx.stroke
          end
        end

        def arc(cx, cy, r, start_angle, stop_angle)
          @ctx.beginPath
          @ctx.arc(cx, cy, r, start_angle, stop_angle)
          if @fill_enabled
            @ctx[:fillStyle] = @fill_color
            @ctx.fill
          end
          if @stroke_enabled
            @ctx[:strokeStyle] = @stroke_color
            @ctx[:lineWidth] = @stroke_weight
            @ctx.stroke
          end
        end

        def set_pixel(x, y, c)
          @ctx[:fillStyle] = rgb332_to_css(c)
          @ctx.fillRect(x, y, 1, 1)
        end

        def text(str, x, y)
          @ctx[:font] = "\#{@text_font[1]}px \#{@text_font[0]}"
          @ctx[:fillStyle] = @text_color
          @ctx[:textAlign] = @text_align_h
          @ctx[:textBaseline] = @text_align_v
          @ctx.fillText(str.to_s, x, y)
        end

        def color(r, g, b)
          (r.to_i & 0xE0) | ((g.to_i >> 3) & 0x1C) | ((b.to_i >> 6) & 0x03)
        end

        private

        def rgb332_to_css(val)
          v = val.to_i & 0xFF
          r = ((v >> 5) & 0x7) * 255 / 7
          g = ((v >> 2) & 0x7) * 255 / 7
          b = (v & 0x3) * 255 / 3
          "rgb(\#{r},\#{g},\#{b})"
        end
      end
    `;

    const params = new URLSearchParams(location.search);
    const seconds = params.get("seconds") || "150";
    const statusEl = document.getElementById("status");

    async function main() {
      statusEl.textContent = "Loading ruby.wasm...";
      const response = await fetch(
        "https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@2.8.1/dist/ruby+stdlib.wasm"
      );
      const module = await WebAssembly.compileStreaming(response);
      const { vm } = await DefaultRubyVM(module);

      window.RUBYKAJA_APP_CODE = APP_CODE;
      window.RUBYKAJA_SECONDS = seconds;

      try {
        vm.eval(SHIM_CODE);
      } catch (e) {
        statusEl.textContent = "Shim error: " + e;
        throw e;
      }

      vm.eval(`
        Object.const_set(:ARGV, []) unless Object.const_defined?(:ARGV)
        ARGV.clear
        ARGV << JS.global[:RUBYKAJA_SECONDS].to_s
        $app_fiber = Fiber.new do
          begin
            eval(JS.global[:RUBYKAJA_APP_CODE].to_s)
          rescue => e
            JS.global[:console].error("App error: " + e.full_message)
          end
        end
      `);

      const canvas = document.getElementById("p5_canvas");
      canvas.focus();
      statusEl.textContent = "Running. Click canvas to focus, then Enter to start.";

      function mapKey(evt) {
        if (evt.ctrlKey && evt.key.length === 1) {
          const c = evt.key.toLowerCase().charCodeAt(0) - 96;
          if (c >= 1 && c <= 26) return String.fromCharCode(c);
        }
        switch (evt.key) {
          case "Enter":     return "\\r";
          case "Escape":    return "\\u001b";
          case "Tab":       return "\\t";
          case "Backspace": return "\\b";
          case "ArrowUp":   return "\\u001bUP";
          case "ArrowDown": return "\\u001bDOWN";
          case "ArrowLeft": return "\\u001bLEFT";
          case "ArrowRight":return "\\u001bRIGHT";
        }
        if (evt.key.length === 1) return evt.key;
        return null;
      }

      function escapeForRubyDoubleQuotes(s) {
        return s.replace(/\\\\/g, "\\\\\\\\")
                .replace(/"/g, '\\\\"')
                .replace(/\\n/g, "\\\\n")
                .replace(/\\r/g, "\\\\r")
                .replace(/\\t/g, "\\\\t");
      }

      window.addEventListener("keydown", (evt) => {
        const code = mapKey(evt);
        console.log("keydown:", evt.key, "->", code === null ? "(unmapped)" : JSON.stringify(code));
        if (code === null) return;
        try {
          const escaped = escapeForRubyDoubleQuotes(code);
          const rubyExpr = '$keyboard.push("' + escaped + '")';
          vm.eval(rubyExpr);
          const qlen = vm.eval('$keyboard.instance_variable_get(:@queue).length').toString();
          console.log("  pushed, queue length:", qlen);
        } catch (e) {
          console.error("key dispatch failed", e);
        }
        if (["Enter","Escape","Tab","Backspace","ArrowUp","ArrowDown","ArrowLeft","ArrowRight"," "].includes(evt.key)) {
          evt.preventDefault();
        }
      });

      let tickCount = 0;
      function tick() {
        try {
          const alive = vm.eval('$app_fiber.alive?').toString() === "true";
          if (alive) {
            vm.eval('$app_fiber.resume');
            tickCount++;
            if (tickCount % 60 === 0) {
              const qlen = vm.eval('$keyboard.instance_variable_get(:@queue).length').toString();
              console.log("tick", tickCount, "queue len:", qlen);
            }
            requestAnimationFrame(tick);
          } else {
            statusEl.textContent = "App finished. Reload to restart.";
            console.log("Fiber dead after", tickCount, "ticks");
          }
        } catch (e) {
          console.error(e);
          statusEl.textContent = "Runtime error: " + e;
        }
      }
      requestAnimationFrame(tick);
    }

    main().catch((e) => {
      console.error(e);
      statusEl.textContent = "Failed to start: " + e;
    });
    </script>
  </body>
  </html>
HTML

File.write(OUTPUT_PATH, html)
puts "Wrote #{OUTPUT_PATH}"
puts "Open with: xdg-open #{OUTPUT_PATH}"
