# johakyu シーン: ゆったりウォッシュ (息づく明るさ + ゆっくり色替え) (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# パンをゆっくり左右に振りつつ、dimmer が息づき、色がゆっくり替わる。
track(:wash) do
  dmx(:all).pan(sine.range(0.55, 0.79).slow(8))
           .tilt(0.32)
           .color("<red blue pink yellow>")
           .gobo(:gobo4)
           .prism(:rotate)
           .dimmer(sine.range(0.3, 1.0).slow(3))
end
