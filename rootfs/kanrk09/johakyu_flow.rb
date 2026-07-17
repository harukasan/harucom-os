# johakyu シーン: 左→右に流れてふわっと消える (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# パンは saw で左→右へ一定に流れ、dimmer は tri でふわっと出て消える。
# 右端で暗くなっている間にパンが左へ戻るので、また左から流れて見える。
track(:flow) do
  dmx(:all).pan(saw.range(0.45, 0.90).slow(2))       # 左→右
           .dimmer(tri.range(-0.3, 1.0).slow(2))      # 両端は負→0クランプで完全消灯
           .tilt(0.30)
           .color(:light_blue)
end
