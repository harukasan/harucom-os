# zoom: Switch the text console pixel scaling
#
# Usage from IRB:
#   zoom     (show the current zoom factor)
#   zoom 1   (640x480, 106x37 characters)
#   zoom 2   (2x pixels, 320x240, 53x18 characters)
#
# Ctrl-Shift-= at the IRB prompt toggles the same setting. The boot
# default comes from CONSOLE_ZOOM in /etc/env.yml.

case ARGV[0]
when nil
  factor = DVI::Text::COLS / DVI::Text.cols
  puts "zoom #{factor} (#{DVI::Text.cols}x#{DVI::Text.rows} characters)"
when "1"
  DVI::Text.set_resolution(640, 480)
  $console.reset
when "2"
  DVI::Text.set_resolution(320, 240)
  $console.reset
else
  puts "Usage: zoom [1|2]"
  exit 1
end
