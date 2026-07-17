# johakyu シーン: プリズム回転 + ランダム移動 (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# パンとチルトを非整数比 (7:9) で重ねると軌道が閉じず、ランダムに動きまわって
# 見える。プリズムは回転させっぱなし。
track(:wander) do
  dmx(:all).pan(cosine.range(0.45, 0.85).slow(7))
           .tilt(sine.range(0.15, 0.45).slow(9))
           .prism(:rotate)      # 0.8 ≒ 204 → プリズム回転
           .color(:red)
           .dimmer(1.0)
end
