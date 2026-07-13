# 序 (jo): the quiet opening. Basic forms played alone: a sparse
# heartbeat, home pose, one slow sway. Scene loaded by F1; apply with
# F5. Swap forms from the catalog:
#   jo("kick2") jo("kick4") jo("backbeat") jo("snare24") jo("hats8")
#   jo("tilt_ud") jo("dimmer_beat") jo("color_cycle") jo("focus_sweep")

tempo 90

track(:beat) { jo("heartbeat") }
track(:home) { jo("home") }
track(:sway) { jo("pan_lr", slow: 12) }
track(:glow) { jo("dimmer_wave", slow: 8) }
