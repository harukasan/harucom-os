fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

track(:drums) { sound("bd ~ [sd sd] ~, hh*8").color("<red blue>").on(:s1) }

track(:wash) { dmx(:s2).dimmer(sine.slow(2)).pan(sine.range(0.3, 0.7).slow(8)) }

# Alt-1..0 switch scenes, Ctrl-O opens a file; Ctrl-Enter applies the buffer.
