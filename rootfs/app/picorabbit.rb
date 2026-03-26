require "p5"
require "picorabbit"

path = ARGV[0]
unless path
  puts "Usage: picorabbit <file>"
  return
end

path = "/#{path}" unless path.start_with?("/")

p5 = P5.new
DVI::Graphics.set_resolution(640, 480)

slides = PicoRabbit::Parser.parse_file(path)
theme = PicoRabbit::Themes::Default.new
renderer = PicoRabbit::Renderer.new(p5, theme)

PicoRabbit::Presenter.new(
  slides: slides,
  renderer: renderer,
  keyboard: $keyboard
).start

DVI.set_mode(DVI::TEXT_MODE)
DVI::Text.clear(0xF0)
DVI::Text.commit
