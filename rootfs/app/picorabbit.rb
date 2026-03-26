require "p5"
require "picorabbit"

path = ARGV[0]
unless path
  puts "Usage: picorabbit <file>"
  return
end

path = "/#{path}" unless path.start_with?("/")

# Parse and resolve theme before switching to graphics mode
result = PicoRabbit::Parser.parse_file(path)

if result.theme
  require "picorabbit/themes/#{result.theme}"
end

theme_class = PicoRabbit::Themes::Default
if result.theme
  name = result.theme.split("_").map { |w| w[0].upcase + w[1, w.length - 1] }.join
  theme_class = PicoRabbit::Themes.const_get(name)
end

# Switch to graphics mode after theme is ready
p5 = P5.new
DVI::Graphics.set_resolution(640, 480)

renderer = PicoRabbit::Renderer.new(p5, theme_class.new)

PicoRabbit::Presenter.new(
  slides: result.slides,
  renderer: renderer,
  keyboard: $keyboard
).start

DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.commit
