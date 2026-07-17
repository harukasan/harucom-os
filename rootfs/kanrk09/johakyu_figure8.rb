# johakyu シーン: 八の字 (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# チルトをパンの2倍の速さ (slow(4) 対 slow(8)) にすると軌道が8の字になる。
track(:figure8) do
  dmx(:all).pan(cosine.range(0.50, 0.84).slow(4))
           .tilt(sine.range(0.08, 0.38).slow(2))     # パンの2倍速
           .color(:pink)
           .prism(:rotate)
           .dimmer(1.0)
end
