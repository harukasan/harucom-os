# 序 (jo): the quiet opening. Basic forms played alone: a sparse
# heartbeat, home pose, one slow sway. Open into a scene with Ctrl-O;
# apply with F5. Swap forms from the catalog:
#   jo("kick2") jo("kick4") jo("backbeat") jo("snare24") jo("hats8")
#   jo("tilt_ud") jo("dimmer_beat") jo("color_cycle") jo("focus_sweep")

$LOAD_PATH << "/data/johakyu" unless $LOAD_PATH.include?("/data/johakyu")
require "catalog"

tempo 90

track(:beat) { jo("heartbeat") }
track(:home) { jo("home") }
track(:sway) { jo("pan_lr", slow: 12) }
track(:glow) { jo("dimmer_wave", slow: 8) }
