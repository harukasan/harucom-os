# johakyu シーン: 左右対称ファン (2灯が開いて閉じる) (light only)
# johakyu アプリで開いて Ctrl-Enter で適用。
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2

tempo 120

# 中心 (0.667) から s1 は左へ、s2 は右へ、tri で対称に開いて閉じる。
track(:fan) do
  stack(
    dmx(:s1).pan(tri.range(0.667, 0.52).slow(2)).tilt(0.20).color(:yellow).dimmer(1.0),
    dmx(:s2).pan(tri.range(0.667, 0.82).slow(2)).tilt(0.20).color(:yellow).dimmer(1.0)
  )
end
