# 急 (kyu): the climax. Everything faster, wider, brighter. Scene
# loaded by F3; apply with F5. Build your own development on top:
#   track(:finale) { kyu("finale") }   # full-on ending

tempo 140

track(:drums) { sound("bd*4, [~ sd]*2, hh*8").every(4) { |p| p.fast(2) } }
track(:spin)  { kyu("spin", slow: 2) }
track(:burst) { kyu("strobe_burst") }
track(:hue)   { ha("color_beat", steps: "1 1 1 1", colors: "<red white blue yellow>") }
