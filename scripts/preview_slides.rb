#!/usr/bin/env ruby
# frozen_string_literal: true

# PicoRabbit slide previewer
#
# Parses PicoRabbit markdown slides and generates an HTML file for
# previewing on a PC. Reuses the actual PicoRabbit parser so the
# preview matches what the hardware renders.
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
  }
}

def theme_css_vars(theme_name)
  colors = THEMES[theme_name] || THEMES["default"]
  colors.map { |k, v| "  --#{k.to_s.tr("_", "-")}: #{rgb332_to_css(v)};" }.join("\n")
end

# Convert inline formatting (**bold** and `code`) to HTML
def inline_to_html(text)
  return "" unless text
  html = text.dup
  # Escape HTML
  html.gsub!("&", "&amp;")
  html.gsub!("<", "&lt;")
  html.gsub!(">", "&gt;")
  # Bold: **text**
  html.gsub!(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
  # Inline code: `text`
  html.gsub!(/`(.+?)`/, '<code class="inline-code">\1</code>')
  html
end

def escape_html(text)
  return "" unless text
  text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def element_to_html(element)
  case element.type
  when :text
    align = element.align ? " style=\"text-align: #{element.align}\"" : ""
    "<p class=\"body-text\"#{align}>#{inline_to_html(element.text)}</p>"
  when :bullet
    indent_style = element.level > 0 ? " style=\"margin-left: #{element.level * 20}px\"" : ""
    "<div class=\"bullet\"#{indent_style}><span class=\"bullet-char\">-</span> #{inline_to_html(element.text)}</div>"
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
    code = lines.map { |l| escape_html(l) }.join("\n")
    "<pre class=\"code-block p5-code\"><code>#{code}</code></pre>"
  when :blank
    "<div class=\"blank\"></div>"
  when :wait
    "<div class=\"wait-marker\"></div>"
  else
    ""
  end
end

def slide_to_html(slide, index, total, metadata)
  parts = []
  parts << "<div class=\"slide\" data-index=\"#{index}\">"

  if slide.title_slide
    parts << "  <div class=\"title-slide-content\">"
    parts << "    <div class=\"title-slide-title\">#{escape_html(slide.title)}</div>"
    if metadata["subtitle"]
      parts << "    <div class=\"title-slide-subtitle\">#{escape_html(metadata["subtitle"])}</div>"
    end
    if metadata["author"]
      parts << "    <div class=\"title-slide-author\">#{escape_html(metadata["author"])}</div>"
    end
    parts << "  </div>"
  else
    if slide.title
      parts << "  <div class=\"slide-title\">#{escape_html(slide.title)}</div>"
      parts << "  <div class=\"separator\"></div>"
    end
    parts << "  <div class=\"slide-body\">"
    slide.elements.each do |el|
      parts << "    #{element_to_html(el)}"
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
    slide_to_html(s, i, result.slides.length, result.metadata)
  }.join("\n\n")

  title = escape_html(result.metadata["title"] || "PicoRabbit Preview")

  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>#{title}</title>
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
      font-family: Helvetica, Arial, sans-serif;
      font-size: 24px;
      font-weight: bold;
      color: var(--title);
      text-align: center;
    }
    .title-slide-subtitle {
      font-family: Helvetica, Arial, sans-serif;
      font-size: 18px;
      color: var(--text);
      margin-top: 12px;
      text-align: center;
    }
    .title-slide-author {
      font-family: Helvetica, Arial, sans-serif;
      font-size: 18px;
      color: var(--separator);
      margin-top: 8px;
      text-align: center;
    }

    /* Slide title */
    .slide-title {
      font-family: Helvetica, Arial, sans-serif;
      font-size: 24px;
      font-weight: bold;
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
      font-family: Helvetica, Arial, sans-serif;
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
      font-family: Helvetica, Arial, sans-serif;
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
    }
    .bullet strong { font-weight: bold; }

    /* Numbered list */
    .numbered {
      font-family: Helvetica, Arial, sans-serif;
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
      font-family: Helvetica, Arial, sans-serif;
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
    .p5-code {
      border-left: 3px solid var(--inline-code);
    }

    /* Image */
    .image { margin-bottom: 4px; }
    .image img { max-width: 560px; image-rendering: pixelated; }
    .image-center { text-align: center; }
    .image-right { text-align: right; }

    /* Blank */
    .blank { height: 11px; }

    /* Wait marker (invisible, used for step logic) */
    .wait-marker { display: none; }

    /* Footer */
    .footer {
      position: absolute;
      bottom: 12px;
      right: 40px;
      font-family: monospace;
      font-size: 7px;
      color: var(--footer);
    }

    /* Navigation hint */
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
    </style>
    </head>
    <body>
    <div class="viewport" id="viewport">
    #{slides_html}
    </div>
    <div class="slide-counter" id="counter"></div>
    <div class="nav-hint"><kbd>&larr;</kbd> / <kbd>&rarr;</kbd> navigate &nbsp; <kbd>Home</kbd> first &nbsp; <kbd>End</kbd> last</div>

    <script>
    (function() {
      const slides = document.querySelectorAll('.slide');
      let current = 0;
      let step = 0;

      function waitCount(slide) {
        return slide.querySelectorAll('.wait-marker').length;
      }

      // Apply wait/step visibility: hide elements after the (step)-th wait marker
      function applyStep(slide, step) {
        const body = slide.querySelector('.slide-body');
        if (!body) return;
        const children = body.children;
        let waits = 0;
        // Reset numbered list counter per slide
        let numberedCounter = 0;
        for (let i = 0; i < children.length; i++) {
          const el = children[i];
          if (el.classList.contains('wait-marker')) {
            waits++;
            if (waits > step) {
              // Hide remaining elements
              for (let j = i + 1; j < children.length; j++) {
                children[j].style.display = 'none';
              }
              return;
            }
          } else {
            el.style.display = '';
            // Re-number numbered lists (reset counter when type changes)
            if (el.classList.contains('numbered')) {
              numberedCounter++;
              // Update the CSS counter by setting a custom attribute
            } else {
              numberedCounter = 0;
            }
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
          (current + 1) + ' / ' + slides.length + (waitCount(slides[current]) > 0 ? '  step ' + step + '/' + waitCount(slides[current]) : '');
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

      show();
    })();
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
