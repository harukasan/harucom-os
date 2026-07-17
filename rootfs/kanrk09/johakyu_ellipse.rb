# johakyu シーン: 楕円 (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

track(:ellipse) do
  dmx(:all).pan(cosine.range(0.667 - 0.1, 0.667 + 0.1).slow(2))
           .tilt(sine.range(0.1, 0.2).slow(2))
           .color(:green)
           .dimmer(1.0)
end
