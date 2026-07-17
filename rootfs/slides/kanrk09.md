---
title: 「照らす技術」を<br>Rubyで照らす
subtitle: 関西Ruby会議09
author: Shunsuke Michii<br>@harukasan
theme: kanrk09
allotted_time: 20
---

# 自己紹介

道井 俊介 / **はるかさん**

* ピクシブ株式会社 執行役員 CTO
* PicoPicoRuby に出没している
* 機材をみるのがすき

# Harucom

* モニターとキーボードだけでうごく<br>ちいさな Ruby コンピューター
* BOOTH で頒布してます!
* harukasan.booth.pm

# 照

```p5_setup
sho = PicoRabbit::BMP.load("/data/sho.bmp")
sho_x = (640 - sho.width) / 2
sho_y = (480 - sho.height) / 2
```

```p5
p5.background(0x00)
p5.image_masked(sho.data, sho.mask, sho_x, sho_y, sho.width, sho.height)
```

# 今日のねらい

- ふだん触れない世界に触れる
- AIでできるからこそ理解を試みる
- よくわからないことについて話す

# 舞台照明のしくみ

```p5_setup
boxes = ["Console", "Dimmer", "Fixture"]
jp = ["調光卓", "調光器", "灯体"]
latin_font = DVI::Graphics::FONT_MPLUS_1_MEDIUM_32_LATIN
wide_font = DVI::Graphics::FONT_MPLUS_1_MEDIUM_32_JAPANESE
p5.text_font(latin_font, wide_font)
fh = DVI::Graphics.font_height(wide_font)
pad_x = 16
pad_y = 10
line_gap = 4
bw = 0
i = 0
while i < boxes.size
  w1 = p5.text_width(boxes[i])
  w2 = p5.text_width(jp[i])
  w = w1 > w2 ? w1 : w2
  bw = w + pad_x * 2 if w + pad_x * 2 > bw
  i += 1
end
bh = pad_y * 2 + fh * 2 + line_gap
line2_dy = pad_y + fh + line_gap
gap = 32
total_w = boxes.size * bw + (boxes.size - 1) * gap
sx = 320 - total_w / 2
sy = 96 + (360 - bh) / 2
```

```p5
p5.text_font(latin_font, wide_font)
p5.text_align(:center)
i = 0
while i < boxes.size
  x = sx + i * (bw + gap)
  p5.no_fill
  p5.stroke(0x92)
  p5.stroke_weight(2)
  p5.rect(x, sy, bw, bh)
  p5.no_stroke
  p5.text_color(0x00)
  p5.text(boxes[i], x + bw / 2, sy + pad_y)
  p5.text(jp[i], x + bw / 2, sy + line2_dy)
  i += 1
end
p5.stroke(0x92)
p5.stroke_weight(2)
i = 0
while i < boxes.size - 1
  x1 = sx + i * (bw + gap) + bw
  x2 = sx + (i + 1) * (bw + gap)
  ay = sy + bh / 2
  p5.line(x1, ay, x2, ay)
  p5.line(x2, ay, x2 - 5, ay - 5)
  p5.line(x2, ay, x2 - 5, ay + 5)
  i += 1
end
```

# トライアック調光

交流波形の一部を落とし電力を調整

```p5_setup
wx = 80
wy = 280
ww = 480
wh = 55
```

```p5
cut = 0.5 + 0.5 * Math.sin(DVI.frame_count * 0.02)
p5.stroke(0x92)
p5.stroke_weight(1)
p5.line(wx, wy, wx + ww, wy)
px = 0
while px < ww
  t1 = px * 4.0 * Math::PI / ww
  t2 = (px + 4) * 4.0 * Math::PI / ww
  y1 = wy - Math.sin(t1) * wh
  y2 = wy - Math.sin(t2) * wh
  p5.line(wx + px, y1.round, wx + px + 4, y2.round)
  px += 4
end
p5.stroke(0xE0)
p5.stroke_weight(5)
hw = ww / 4
k = 0
while k < 4
  x0 = wx + k * hw
  xc = x0 + (hw * cut).to_i
  p5.line(x0, wy, xc, wy) if xc > x0
  first = true
  px = xc
  while px < x0 + hw
    q = px + 4
    q = x0 + hw if q > x0 + hw
    y1 = wy - Math.sin((px - wx) * 4.0 * Math::PI / ww) * wh
    y2 = wy - Math.sin((q - wx) * 4.0 * Math::PI / ww) * wh
    p5.line(px, wy, px, y1.round) if first && y1.round != wy
    first = false
    p5.line(px, y1.round, q, y2.round)
    px = q
  end
  k += 1
end
```

# LED照明

* 省電力、低発熱、高機能
* 多くの照明が単体で調光機能を内蔵

# Rubyで照らす

# Lチカ

# PWM

* PWM = Pulse Width Modulation
  * 周波数: 1秒あたりのサイクル数
  * デューティー比: ONの時間の割合

```p5_setup
wx = 100
wy = 320
ww = 400
wh = 60
periods = 4
```

```p5
duty = 0.5 + 0.45 * Math.sin(DVI.frame_count * 0.02)
pw = ww / periods
p5.stroke(0xE0)
p5.stroke_weight(2)
i = 0
while i < periods
  x0 = wx + i * pw
  xm = x0 + (pw * duty).to_i
  p5.line(x0, wy + wh, x0, wy)
  p5.line(x0, wy, xm, wy)
  p5.line(xm, wy, xm, wy + wh)
  p5.line(xm, wy + wh, x0 + pw, wy + wh)
  i += 1
end
v = (duty * 255).to_i
p5.no_stroke
p5.fill(p5.color(v, v, 0))
p5.rect(540, wy, 44, wh)
p5.no_fill
p5.stroke(0x00)
p5.stroke_weight(2)
p5.rect(540, wy, 44, wh)
```

# 調光の制御

- たくさんの照明をブースから操作
- 少ない配線で通信したい
- 互換性がないと大変

# DMX512

**D**igital **M**ultiple**x** **512**

# Universe

- 512chを多重化(Multiplex)する
- これを 1 Universe (宇宙) と呼ぶ

```p5_setup
boxes = ["Console", "Fixture", "Fixture", "Fixture"]
addrs = [nil, "Addr 1", "Addr 14", "Addr 27"]
starts = [nil, 1, 14, 27]
span = 13
bw = 110
bh = 48
gap = 40
total_w = boxes.size * bw + (boxes.size - 1) * gap
sx = 320 - total_w / 2
sy = 360
ux = sx
uw = total_w
uy = 244
uh = 30
chw = uw.to_f / 512
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_18)
p5.text_align(:center)

# Daisy chain of the console and fixtures
i = 0
while i < boxes.size
  x = sx + i * (bw + gap)
  p5.no_fill
  p5.stroke(0x92)
  p5.stroke_weight(2)
  p5.rect(x, sy, bw, bh)
  p5.no_stroke
  p5.text_color(0x00)
  p5.text(boxes[i], x + bw / 2, sy + 16)
  if addrs[i]
    p5.text_color(0x64)
    p5.text(addrs[i], x + bw / 2, sy + bh + 10)
  end
  i += 1
end
p5.stroke(0x92)
p5.stroke_weight(2)
i = 0
while i < boxes.size - 1
  x1 = sx + i * (bw + gap) + bw
  x2 = sx + (i + 1) * (bw + gap)
  ay = sy + bh / 2
  p5.line(x1, ay, x2, ay)
  p5.line(x2, ay, x2 - 5, ay - 5)
  p5.line(x2, ay, x2 - 5, ay + 5)
  i += 1
end

# One universe holds 512 channels
p5.no_fill
p5.stroke(0x92)
p5.stroke_weight(2)
p5.rect(ux, uy, uw, uh)

# Each fixture takes 13 channels from its address, drawn to scale
p5.no_stroke
p5.fill(0x01)
i = 1
while i < boxes.size
  bx = ux + ((starts[i] - 1) * chw).to_i
  p5.rect(bx, uy, (span * chw).to_i - 1, uh)
  i += 1
end
p5.no_fill

# Label the free remainder and the channel scale
used_end = ux + ((starts[boxes.size - 1] - 1 + span) * chw).to_i
free = 512 - span * (boxes.size - 1)
p5.text_color(0x92)
p5.text("Universe", (ux + uw) / 2, uy + uh / 2 - 9)
p5.text_color(0x64)
p5.text_align(:left)
p5.text("1", ux, uy + uh + 8)
p5.text_align(:right)
p5.text("512", ux + uw, uy + uh + 8)
p5.text_align(:center)

# Tie each fixture up to its channel block
p5.stroke(0x92)
p5.stroke_weight(1)
i = 1
while i < boxes.size
  cx = sx + i * (bw + gap) + bw / 2
  bcx = ux + (((starts[i] - 1) + span / 2.0) * chw).to_i
  p5.line(cx, sy, bcx, uy + uh)
  i += 1
end
```

# RS485

- バランス接続のシリアル通信規格
- 差動信号を使用しノイズに強い
- 最大1200m、32台を接続できる

# UART

- よく使われる非同期シリアル通信規格
- DMXの通信設定は 250kbps / 8N2

```
 1 bit           8 bit             2 bit
|start| b0 b1 b2 b3 b4 b5 b6 b7 |stop|stop|

```

# DMXパケット

```p5_setup
cells = ["BREAK", "MAB", "SC", "1", "2", "3", "...", "512"]
widths = [80, 52, 44, 40, 40, 40, 80, 52]
bh = 44
gap = 4
total = gap * (cells.size - 1)
widths.each { |w| total += w }
sx = 320 - total / 2
sy = 110
```

```p5
p5.text_font(DVI::Graphics::FONT_SOURCE_CODE_PRO_18)
p5.text_align(:center)
x = sx
i = 0
while i < cells.size
  w = widths[i]
  if i == 0
    p5.fill(0x24)
    p5.no_stroke
    p5.rect(x, sy, w, bh)
    p5.text_color(0xFF)
  else
    p5.no_fill
    p5.stroke(0x00)
    p5.stroke_weight(2)
    p5.rect(x, sy, w, bh)
    p5.no_stroke
    p5.text_color(0x00)
  end
  p5.text(cells[i], x + w / 2, sy + 14)
  x += w + gap
  i += 1
end
```

- UARTにはパケットの概念がない
- BREAKとMABで"区切り"をつくる
  - BREAK: 最低88us LOWにする
  - MAB: 最低8us HIGHにする
  - SC: 1byteのスタートコード

# ムービングライト

SHEHDS LED Spot 80W (13chモード)

```
ch 1  Pan          ch 8  Color wheel
ch 2  Pan fine     ch 9  Gobo wheel
ch 3  Tilt         ch 10 Focus
ch 4  Tilt fine    ch 11 Prism
ch 5  Speed        ch 12 Motor auto
ch 6  Dimmer       ch 13 Function
ch 7  Strobe
```

# DMXパケットを送信する

構成:
- Harucom (RP2350)
- M5Stack DMXユニット
  - Groveコネクタに接続
  - 絶縁型RS485トランシーバー
  - マイコンとUARTで通信する

# UARTで送ってみる

- picoruby-uartで送信する

{::wait/}

- UART送信はブロッキング
- 送信中にほかのことができない
- そこでDMAを使う
- **picoruby-dmx** をつくった

# picoruby-dmx

- universeバッファをC側で確保
- タイマー/DMAが40fpsでDMXを送信
- Ruby側は値を書くだけでブロックしない

# デッドマンスイッチ

- 灯体は信号がこなくても消えない
- 途絶えるとつけっぱになってしまう
- 使用中はkeepaliveをよぶ
- とまったら自動でブラックアウト

# シーケンサーをつくる

- 複雑なうごきを簡単に書きたい
- 音と光をあわせて動かしたい
- 型をつくって発展させたい

# 序破急

# 序破急

- 音と光を同時に扱えるシーケンサー
- strudel-rb を参考に実装
- DMXをDSLでかんたんに書ける

# QOA

Quite OK Audio

- マイコン向け超軽量フォーマット
- 整数演算だけでうごく
- Cで400行くらい

# まとめ

- 普段さわらない技術にさわるとおもしろい

- X: @harukasan
- GitHub: harukasan/harucom-os
- https://harukasan.dev/
