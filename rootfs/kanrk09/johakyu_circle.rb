# johakyu シーン: 円 (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# パンに cos、チルトに sin。振幅を同じにすると円。slow(n) の n が一周の遅さ。
track(:circle) do
  dmx(:all).pan(cosine.range(0.52, 0.82).slow(2))
           .tilt(sine.range(0.15, 0.45).slow(2))
           .color(:blue)
           .dimmer(1.0)
end
