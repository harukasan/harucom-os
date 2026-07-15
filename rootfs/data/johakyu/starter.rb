fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# s1: the color wheel steps on the dark downbeat, then the lamp
# lights, so the wheel travel is never seen. dimmer comes first so it
# drives the timing; the color is sampled onto each step, and the "0"
# step is the beat where the slowcat picks a new color.
track(:s1) { dmx(:s1).dimmer("0 1 1 1").color("<red blue green>") }

# s2: a slow moving wash.
track(:wash) { dmx(:s2).dimmer(sine.slow(2)).pan(sine.range(0.3, 0.7).slow(8)) }

# Drums keep time; hats ride the eighths.
track(:drums) { sound("bd ~ [sd sd] ~, hh*8") }

# Alt-1..0 switch scenes, Ctrl-O opens a file; Ctrl-Enter applies the buffer.
