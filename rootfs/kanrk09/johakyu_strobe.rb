# johakyu シーン: ストロボ (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# 灯体のハードウェアストロボ。dimmer 全開 + strobe で高速点滅。正面固定。
track(:strobe) do
  dmx(:all).dimmer(1.0)
           .strobe(0.3)  # 0.3-0.8    # 0.8 ≒ 204 → 速いストロボ (小さくすると遅く)
           .color(:white)
           .pan(0.67)
           .tilt(0.20)
           .gobo(0)
           .prism(0)
end
