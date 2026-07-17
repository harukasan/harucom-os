# johakyu シーン: ビートで明滅 + 色替え (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# dimmer を "1 0 1 0" で4分点滅、色は1サイクルごとに替える。正面固定。
track(:pulse) do
  dmx(:all).dimmer("1 0 1 0")                    # 4分で点滅 (structure)
           .color("<red blue green yellow>")     # 1サイクルごとに色替え
           .pan(0.67)
           .tilt(0.25)
end
