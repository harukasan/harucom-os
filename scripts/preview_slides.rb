#!/usr/bin/env ruby
# frozen_string_literal: true

# PicoRabbit slide previewer
#
# Parses PicoRabbit markdown slides and generates a self-contained HTML
# file for previewing on a PC. Reuses the actual PicoRabbit parser so
# the preview matches what the hardware renders.
#
# p5 code blocks are executed via ruby.wasm with a Canvas-backed P5 shim,
# so the same Ruby drawing code runs in the browser.
#
# Usage:
#   ruby tools/preview_slides.rb rootfs/slides/rubykaigi2026.md
#   ruby tools/preview_slides.rb rootfs/slides/rubykaigi2026.md -o preview.html

require_relative "../rootfs/lib/picorabbit/slide"
require_relative "../rootfs/lib/picorabbit/parser"

# RGB332 (RRRGGGBB) to CSS hex color
def rgb332_to_css(val)
  r = ((val >> 5) & 0x7) * 255 / 7
  g = ((val >> 2) & 0x7) * 255 / 7
  b = (val & 0x3) * 255 / 3
  format("#%02x%02x%02x", r, g, b)
end

# Theme color definitions matching PicoRabbit themes
THEMES = {
  "default" => {
    background: 0xFF, title: 0x00, text: 0x00,
    blockquote: 0x49, separator: 0x49, inline_code: 0xE0,
    code_background: 0x49, code_text: 0xFF, footer: 0x49
  },
  "dark" => {
    background: 0x00, title: 0xFF, text: 0xDB,
    blockquote: 0x92, separator: 0x49, inline_code: 0x1C,
    code_background: 0x24, code_text: 0x1C, footer: 0x49
  },
  "rubykaigi2026" => {
    background: 0xFF, title: 0x64, text: 0x00,
    blockquote: 0x49, separator: 0x64, inline_code: 0xE0,
    code_background: 0x49, code_text: 0xFF, footer: 0x49
  }
}

THEME_FONTS = {
  "default" => { heading: "Helvetica, Arial, sans-serif", body: "Helvetica, Arial, sans-serif" },
  "dark" => { heading: "Helvetica, Arial, sans-serif", body: "Helvetica, Arial, sans-serif" },
  "rubykaigi2026" => { heading: "'Outfit', sans-serif", body: "'Outfit', sans-serif" }
}

def theme_css_vars(theme_name)
  colors = THEMES[theme_name] || THEMES["default"]
  fonts = THEME_FONTS[theme_name] || THEME_FONTS["default"]
  vars = colors.map { |k, v| "  --#{k.to_s.tr("_", "-")}: #{rgb332_to_css(v)};" }
  vars << "  --heading-font: #{fonts[:heading]};"
  vars << "  --body-font: #{fonts[:body]};"
  vars.join("\n")
end

# Convert inline formatting (**bold** and `code`) to HTML
def inline_to_html(text)
  return "" unless text
  html = text.dup
  html.gsub!("&", "&amp;")
  html.gsub!("<", "&lt;")
  html.gsub!(">", "&gt;")
  html.gsub!(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
  html.gsub!(/`(.+?)`/, '<code class="inline-code">\1</code>')
  html
end

def escape_html(text)
  return "" unless text
  text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def element_to_html(element, slide_index, theme_name = "default")
  case element.type
  when :text
    align = element.align ? " style=\"text-align: #{element.align}\"" : ""
    "<p class=\"body-text\"#{align}>#{inline_to_html(element.text)}</p>"
  when :bullet
    indent_style = element.level > 0 ? " style=\"margin-left: #{element.level * 20}px\"" : ""
    bullet_char = theme_name == "rubykaigi2026" ? "\u2605" : "-"
    "<div class=\"bullet\"#{indent_style}><span class=\"bullet-char\">#{bullet_char}</span> #{inline_to_html(element.text)}</div>"
  when :numbered
    indent_style = element.level > 0 ? " style=\"margin-left: #{element.level * 20}px\"" : ""
    "<div class=\"numbered\"#{indent_style}>#{inline_to_html(element.text)}</div>"
  when :blockquote
    "<div class=\"blockquote\"><div class=\"blockquote-bar\"></div><span>#{inline_to_html(element.text)}</span></div>"
  when :image
    align_class = element.align ? " image-#{element.align}" : ""
    "<div class=\"image#{align_class}\"><img src=\"#{escape_html(element.text)}\" alt=\"\"></div>"
  when :code_block
    lines = element.text.is_a?(Array) ? element.text : [element.text]
    code = lines.map { |l| escape_html(l) }.join("\n")
    "<pre class=\"code-block\"><code>#{code}</code></pre>"
  when :p5_code
    lines = element.text.is_a?(Array) ? element.text : [element.text]
    code_escaped = lines.join("\n").gsub("\\", "\\\\\\\\").gsub("`", "\\`").gsub("$", "\\$")
    "<div class=\"p5-canvas\" data-p5-code=\"#{encode_p5_code(lines)}\"></div>"
  when :blank
    "<div class=\"blank\"></div>"
  when :wait
    "<div class=\"wait-marker\"></div>"
  else
    ""
  end
end

def encode_p5_code(lines)
  lines.join("\n").gsub("&", "&amp;").gsub("\"", "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def slide_to_html(slide, index, total, metadata, theme_name = "default")
  parts = []
  parts << "<div class=\"slide\" data-index=\"#{index}\">"

  if slide.title_slide
    if theme_name == "rubykaigi2026"
      parts << "  <div class=\"title-slide-background\"><img src=\"data/rubykaigi2026_title.png\" alt=\"\"></div>"
      parts << "  <div class=\"title-slide-content\">"
      parts << "    <div class=\"title-slide-title\" style=\"color: #ffffff;\">#{escape_html(slide.title)}</div>"
      parts << "    <div class=\"title-slide-subtitle\" style=\"color: #dbdbff;\">#{escape_html(metadata["subtitle"])}</div>" if metadata["subtitle"]
      parts << "    <div class=\"title-slide-author\" style=\"color: #dbdbff;\">#{escape_html(metadata["author"])}</div>" if metadata["author"]
      parts << "  </div>"
    else
      parts << "  <div class=\"title-slide-content\">"
      parts << "    <div class=\"title-slide-title\">#{escape_html(slide.title)}</div>"
      parts << "    <div class=\"title-slide-subtitle\">#{escape_html(metadata["subtitle"])}</div>" if metadata["subtitle"]
      parts << "    <div class=\"title-slide-author\">#{escape_html(metadata["author"])}</div>" if metadata["author"]
      parts << "  </div>"
    end
  else
    parts << "  <div class=\"accent-bar\"></div>" if theme_name == "rubykaigi2026"
    if slide.title
      parts << "  <div class=\"slide-title\">#{escape_html(slide.title)}</div>"
      parts << "  <div class=\"separator\"></div>"
    end
    parts << "  <div class=\"slide-body\">"
    slide.elements.each do |el|
      parts << "    #{element_to_html(el, index, theme_name)}"
    end
    parts << "  </div>"
  end

  parts << "  <div class=\"footer\">#{index + 1} / #{total}</div>"
  parts << "</div>"
  parts.join("\n")
end

def generate_html(result)
  theme_name = result.theme || "default"
  slides_html = result.slides.each_with_index.map { |s, i|
    slide_to_html(s, i, result.slides.length, result.metadata, theme_name)
  }.join("\n\n")

  title = escape_html(result.metadata["title"] || "PicoRabbit Preview")

  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>#{title}</title>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;800&display=swap">
    <style>
    :root {
    #{theme_css_vars(theme_name)}
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      background: #222;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      font-family: sans-serif;
      overflow: hidden;
    }

    .viewport {
      width: 640px;
      height: 480px;
      position: relative;
      overflow: hidden;
      box-shadow: 0 4px 24px rgba(0,0,0,0.5);
    }

    .slide {
      width: 640px;
      height: 480px;
      background: var(--background);
      position: absolute;
      top: 0;
      left: 0;
      display: none;
      padding: 0;
      overflow: hidden;
    }

    .slide.active {
      display: block;
    }

    /* Title slide */
    .title-slide-content {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      position: absolute;
      top: 180px;
      left: 0;
      right: 0;
    }
    .title-slide-title {
      font-family: var(--heading-font);
      font-size: 32px;
      font-weight: 800;
      color: var(--title);
      text-align: center;
    }
    .title-slide-subtitle {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--text);
      margin-top: 12px;
      text-align: center;
    }
    .title-slide-author {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--separator);
      margin-top: 8px;
      text-align: center;
    }

    /* Slide title */
    .slide-title {
      font-family: var(--heading-font);
      font-size: 32px;
      font-weight: 800;
      color: var(--title);
      position: absolute;
      top: 40px;
      left: 40px;
      right: 40px;
    }
    .separator {
      position: absolute;
      top: 76px;
      left: 40px;
      right: 40px;
      height: 1px;
      background: var(--separator);
    }

    /* Slide body */
    .slide-body {
      position: absolute;
      top: 88px;
      left: 40px;
      right: 40px;
      bottom: 40px;
    }

    /* Body text */
    .body-text {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--text);
      line-height: 1;
      margin-bottom: 4px;
    }
    .body-text strong {
      font-weight: bold;
    }

    /* Bullet */
    .bullet {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--text);
      line-height: 1;
      margin-bottom: 4px;
      padding-left: 16px;
    }
    .bullet .bullet-char {
      display: inline-block;
      width: 16px;
      margin-left: -16px;
      color: var(--title);
    }
    .bullet strong { font-weight: bold; }

    /* Numbered list */
    .numbered {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--text);
      line-height: 1;
      margin-bottom: 4px;
      padding-left: 16px;
      counter-increment: numbered-list;
    }
    .numbered::before {
      content: counter(numbered-list) ".";
      display: inline-block;
      width: 16px;
      margin-left: -16px;
    }
    .numbered strong { font-weight: bold; }

    /* Blockquote */
    .blockquote {
      display: flex;
      align-items: stretch;
      margin-bottom: 4px;
    }
    .blockquote-bar {
      width: 3px;
      background: var(--separator);
      margin-right: 12px;
      margin-left: 4px;
      flex-shrink: 0;
      min-height: 22px;
    }
    .blockquote span {
      font-family: var(--body-font);
      font-size: 18px;
      color: var(--blockquote);
      line-height: 1;
    }

    /* Inline code */
    .inline-code {
      font-family: 'Courier New', Courier, monospace;
      font-size: 16px;
      color: var(--inline-code);
    }

    /* Code block */
    .code-block {
      background: var(--code-background);
      padding: 6px;
      margin-bottom: 4px;
      font-family: 'Courier New', Courier, monospace;
      font-size: 16px;
      line-height: 18px;
      color: var(--code-text);
      white-space: pre;
      overflow: hidden;
    }

    /* P5 canvas */
    .p5-canvas {
      position: absolute;
      top: 0;
      left: 0;
      width: 640px;
      height: 480px;
      pointer-events: none;
    }
    .p5-canvas canvas {
      position: absolute;
      top: 0;
      left: 0;
    }

    /* Image */
    .image { margin-bottom: 4px; }
    .image img { max-width: 560px; image-rendering: pixelated; }
    .image-center { text-align: center; }
    .image-right { text-align: right; }

    /* Blank */
    .blank { height: 11px; }

    /* Wait marker */
    .wait-marker { display: none; }

    /* Theme: rubykaigi2026 top accent bar */
    .accent-bar {
      position: absolute;
      top: 0;
      left: 0;
      width: 640px;
      height: 10px;
      background: var(--separator);
      z-index: 1;
    }

    /* Theme: rubykaigi2026 title slide background */
    .title-slide-background {
      position: absolute;
      top: 0;
      left: 0;
      width: 640px;
      height: 480px;
    }
    .title-slide-background img {
      width: 100%;
      height: 100%;
      image-rendering: pixelated;
    }

    /* Footer */
    .footer {
      position: absolute;
      bottom: 12px;
      right: 40px;
      font-family: monospace;
      font-size: 7px;
      color: var(--footer);
    }

    /* Navigation */
    .nav-hint {
      color: #888;
      font-size: 13px;
      margin-top: 12px;
      font-family: monospace;
    }
    .nav-hint kbd {
      background: #444;
      color: #ccc;
      padding: 2px 6px;
      border-radius: 3px;
      font-size: 12px;
    }
    .slide-counter {
      color: #888;
      font-size: 13px;
      margin-top: 6px;
      font-family: monospace;
    }

    /* Loading indicator */
    #loading {
      color: #888;
      font-family: monospace;
      font-size: 13px;
      margin-top: 8px;
    }
    </style>
    </head>
    <body>
    <div class="viewport" id="viewport">
    #{slides_html}
    </div>
    <div class="slide-counter" id="counter"></div>
    <div class="nav-hint"><kbd>&larr;</kbd> / <kbd>&rarr;</kbd> navigate &nbsp; <kbd>Home</kbd> first &nbsp; <kbd>End</kbd> last</div>
    <div id="loading">Loading ruby.wasm...</div>

    <script type="module">
    import { DefaultRubyVM } from "https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.8.1/dist/browser/+esm";

    // P5 shim: Ruby class that draws on a Canvas 2D context via JS interop.
    // Provides the same API as PicoRabbit's P5 wrapper so slide code runs unchanged.
    const P5_SHIM_CODE = `
    require "js"

    module DVI
      module Graphics
        # Font constants (name, size pairs used by the shim)
        FONT_HELVETICA_BOLD_24 = [:helvetica_bold, 24]
        FONT_HELVETICA_18 = [:helvetica, 18]
        FONT_HELVETICA_BOLD_18 = [:helvetica_bold, 18]
        FONT_SPLEEN_8X16 = [:monospace, 16]
        FONT_FIXED_5X7 = [:monospace, 7]

        def self.font_height(font)
          font[1]
        end
      end
    end

    class P5Shim
      def initialize(canvas_id)
        @canvas = JS.global[:document].getElementById(canvas_id)
        @ctx = @canvas.getContext("2d")
        @width = 640
        @height = 480
        @fill_color = nil
        @stroke_color = nil
        @text_font_name = "18px Helvetica, Arial, sans-serif"
        @text_color_css = "#ffffff"
        @text_align_val = "left"
        @text_baseline = "top"
      end

      def rgb332_to_css(val)
        val = val.to_i
        r = ((val >> 5) & 0x7) * 255 / 7
        g = ((val >> 2) & 0x7) * 255 / 7
        b = (val & 0x3) * 255 / 3
        "rgb(" + r.to_s + "," + g.to_s + "," + b.to_s + ")"
      end

      def color(r, g, b)
        # Convert component RGB to RGB332
        r3 = (r * 7 / 255) & 0x7
        g3 = (g * 7 / 255) & 0x7
        b2 = (b * 3 / 255) & 0x3
        (r3 << 5) | (g3 << 2) | b2
      end

      def background(c)
        css = rgb332_to_css(c)
        @ctx[:fillStyle] = css
        @ctx.fillRect(0, 0, @width, @height)
      end

      def fill(c)
        @fill_color = rgb332_to_css(c)
      end

      def no_fill
        @fill_color = nil
      end

      def stroke(c)
        @stroke_color = rgb332_to_css(c)
      end

      def no_stroke
        @stroke_color = nil
      end

      def rect(x, y, w, h)
        if @fill_color
          @ctx[:fillStyle] = @fill_color
          @ctx.fillRect(x, y, w, h)
        end
        if @stroke_color
          @ctx[:strokeStyle] = @stroke_color
          @ctx.strokeRect(x, y, w, h)
        end
      end

      def line(x1, y1, x2, y2)
        return unless @stroke_color
        @ctx[:strokeStyle] = @stroke_color
        @ctx.beginPath
        @ctx.moveTo(x1, y1)
        @ctx.lineTo(x2, y2)
        @ctx.stroke
      end

      def circle(cx, cy, r)
        @ctx.beginPath
        @ctx.arc(cx, cy, r, 0, 2 * Math::PI)
        if @fill_color
          @ctx[:fillStyle] = @fill_color
          @ctx.fill
        end
        if @stroke_color
          @ctx[:strokeStyle] = @stroke_color
          @ctx.stroke
        end
      end

      def ellipse(cx, cy, rx, ry)
        @ctx.beginPath
        @ctx.ellipse(cx, cy, rx, ry, 0, 0, 2 * Math::PI)
        if @fill_color
          @ctx[:fillStyle] = @fill_color
          @ctx.fill
        end
        if @stroke_color
          @ctx[:strokeStyle] = @stroke_color
          @ctx.stroke
        end
      end

      def triangle(x1, y1, x2, y2, x3, y3)
        @ctx.beginPath
        @ctx.moveTo(x1, y1)
        @ctx.lineTo(x2, y2)
        @ctx.lineTo(x3, y3)
        @ctx.closePath
        if @fill_color
          @ctx[:fillStyle] = @fill_color
          @ctx.fill
        end
        if @stroke_color
          @ctx[:strokeStyle] = @stroke_color
          @ctx.stroke
        end
      end

      def text_font(font)
        name, size = font
        case name
        when :helvetica_bold
          @text_font_name = size.to_s + "px Helvetica, Arial, sans-serif"
          @ctx[:font] = "bold " + @text_font_name
        when :helvetica
          @text_font_name = size.to_s + "px Helvetica, Arial, sans-serif"
          @ctx[:font] = @text_font_name
        when :monospace
          @text_font_name = size.to_s + "px Courier New, Courier, monospace"
          @ctx[:font] = @text_font_name
        end
      end

      def text_color(c)
        @text_color_css = rgb332_to_css(c)
      end

      def text_align(align)
        case align
        when :center
          @text_align_val = "center"
        when :right
          @text_align_val = "right"
        else
          @text_align_val = "left"
        end
      end

      def text(str, x, y)
        @ctx[:fillStyle] = @text_color_css
        @ctx[:font] = @text_font_name if @text_font_name
        @ctx[:textAlign] = @text_align_val
        @ctx[:textBaseline] = "top"
        @ctx.fillText(str.to_s, x, y)
      end

      def text_width(str)
        @ctx[:font] = @text_font_name if @text_font_name
        metrics = @ctx.measureText(str.to_s)
        metrics[:width].to_f.to_i
      end

      def commit
        # no-op in preview
      end
    end
    `;

    async function initRubyVM() {
      const response = await fetch(
        "https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@2.8.1/dist/ruby+stdlib.wasm"
      );
      const module = await WebAssembly.compileStreaming(response);
      const { vm } = await DefaultRubyVM(module);
      return vm;
    }

    // Slide navigation
    const slides = document.querySelectorAll('.slide');
    let current = 0;
    let step = 0;

    function waitCount(slide) {
      return slide.querySelectorAll('.wait-marker').length;
    }

    function applyStep(slide, currentStep) {
      const body = slide.querySelector('.slide-body');
      if (!body) return;
      const children = body.children;
      let waits = 0;
      for (let i = 0; i < children.length; i++) {
        const el = children[i];
        if (el.classList.contains('wait-marker')) {
          waits++;
          if (waits > currentStep) {
            for (let j = i + 1; j < children.length; j++) {
              children[j].style.display = 'none';
            }
            return;
          }
        } else {
          el.style.display = '';
        }
      }
    }

    let rubyVM = null;
    let p5Initialized = false;

    async function runP5Blocks(slide) {
      if (!rubyVM) return;
      const blocks = slide.querySelectorAll('.p5-canvas');
      for (const block of blocks) {
        // Only run if visible (not hidden by wait step)
        if (block.style.display === 'none') continue;

        const code = block.getAttribute('data-p5-code');
        if (!code) continue;

        // Create or reuse canvas
        let canvas = block.querySelector('canvas');
        if (!canvas) {
          canvas = document.createElement('canvas');
          canvas.width = 640;
          canvas.height = 480;
          canvas.id = 'p5_canvas_' + Math.random().toString(36).slice(2);
          block.appendChild(canvas);
        }

        const ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, 640, 480);

        try {
          rubyVM.eval(`
            p5 = P5Shim.new("${canvas.id}")
            x = 40
            y = 88
            ${code}
          `);
        } catch (e) {
          console.error('P5 code error:', e);
        }
      }
    }

    function show() {
      slides.forEach((s, i) => {
        if (i === current) {
          s.classList.add('active');
          s.style.counterReset = 'numbered-list 0';
          applyStep(s, step);
        } else {
          s.classList.remove('active');
        }
      });
      document.getElementById('counter').textContent =
        (current + 1) + ' / ' + slides.length +
        (waitCount(slides[current]) > 0
          ? '  step ' + step + '/' + waitCount(slides[current])
          : '');
      runP5Blocks(slides[current]);
    }

    function advance() {
      const maxStep = waitCount(slides[current]);
      if (step < maxStep) {
        step++;
      } else if (current < slides.length - 1) {
        current++;
        step = 0;
      }
      show();
    }

    function retreat() {
      if (step > 0) {
        step--;
      } else if (current > 0) {
        current--;
        step = waitCount(slides[current]);
      }
      show();
    }

    document.addEventListener('keydown', function(e) {
      switch (e.key) {
        case 'ArrowRight':
        case 'PageDown':
        case 'Enter':
        case ' ':
          e.preventDefault();
          advance();
          break;
        case 'ArrowLeft':
        case 'PageUp':
        case 'Backspace':
          e.preventDefault();
          retreat();
          break;
        case 'Home':
          e.preventDefault();
          current = 0; step = 0;
          show();
          break;
        case 'End':
          e.preventDefault();
          current = slides.length - 1; step = 0;
          show();
          break;
      }
    });

    // Initialize: show slides immediately, load ruby.wasm in background
    show();

    const loadingEl = document.getElementById('loading');
    try {
      rubyVM = await initRubyVM();
      rubyVM.eval(P5_SHIM_CODE);
      p5Initialized = true;
      loadingEl.textContent = 'ruby.wasm ready';
      setTimeout(() => { loadingEl.style.display = 'none'; }, 1500);
      // Re-render current slide to execute any p5 blocks
      show();
    } catch (e) {
      loadingEl.textContent = 'ruby.wasm failed to load: ' + e.message;
      console.error('ruby.wasm init error:', e);
    }
    </script>
    </body>
    </html>
  HTML
end

# Main
if ARGV.empty?
  $stderr.puts "Usage: ruby tools/preview_slides.rb <slide.md> [-o output.html]"
  exit 1
end

input = ARGV[0]
output = nil
if ARGV[1] == "-o" && ARGV[2]
  output = ARGV[2]
end

result = PicoRabbit::Parser.parse_file(input)
html = generate_html(result)

if output
  File.write(output, html)
  puts "Written to #{output}"
else
  output = input.sub(/\.md$/, ".html")
  File.write(output, html)
  puts "Written to #{output}"
end

puts "#{result.slides.length} slides, theme: #{result.theme || "default"}"
