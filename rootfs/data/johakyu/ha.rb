# 破 (ha): the development. Forms combine: a full beat, circles and
# figure-eights around the stage, colors riding the dimmer. Scene
# loaded by F2; apply with F5. Try:
#   ha("mirror") ha("chase", fast: 2) _track to mute a layer

tempo 120

track(:drums)  { sound("bd*4, ~ sd ~ sd, hh*8") }
track(:orbit)  { ha("circle", on: :s1, slow: 8) }
track(:eight)  { ha("figure8", on: :s2, slow: 8) }
track(:pulse)  { ha("color_beat", colors: "<red blue yellow>") }
