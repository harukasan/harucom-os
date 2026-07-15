---
title: 照らす技術をRubyで照らす
subtitle: 関西Ruby会議09
author: Shunsuke Michii (harukasan)
theme: kanrk09
allotted_time: 20
---

# 自己紹介

みちい しゅんすけ / **はるかさん**
Michii Shunsuke / **Harukasan**

* ピクシブ株式会社 執行役員 CTO
* よく PicoPicoRuby に出没している
* 機材をみるのがすき

# Harucom

モニターとキーボードがあればRubyがうごく
ちいさな Ruby コンピューター

# 照

# 今日のテーマ「照らす」

ふだんは照明があたらない
**裏側のからくり**にスポットライトを

{::wait/}

ムービングスポットライトを2台もってきました

# 舞台照明のしくみ

灯体 = ライトそのもの
調光器 = 電力を絞って明るさをかえる

```p5_setup
boxes = ["Console", "Dimmer", "Fixture"]
jp = ["調光卓", "調光器", "灯体"]
bw = 120
bh = 56
gap = 50
total_w = boxes.size * bw + (boxes.size - 1) * gap
sx = 320 - total_w / 2
sy = 230
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_BOLD_18, DVI::Graphics::FONT_MPLUS_1_MEDIUM_22)
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
  p5.text(boxes[i], x + bw / 2, sy + 7)
  p5.text(jp[i], x + bw / 2, sy + 27)
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

電球は、供給する電力そのものを絞る

```p5_setup
wx = 80
wy = 260
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

交流波形の一部をおとして電力を調整する

# Lチカ

LEDは「点けて、消して」を高速にくりかえす

```ruby
led = GPIO.new(25, GPIO::OUT)

loop do
  led.write 1
  sleep_ms 1000
  led.write 0
  sleep_ms 1000
end
```

{::wait/}

sleepをちぢめていくと……?

# PWM

Pulse Width Modulation
ONの時間の割合(デューティ比)で明るさがかわる

```p5_setup
wx = 100
wy = 230
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
p5.stroke(0x92)
p5.stroke_weight(2)
p5.rect(540, wy, 44, wh)
```

いまのLED照明の多くはPWM調光を内蔵している

# 調光器との通信

- 調光卓は会場のうしろの機材ブースに
- 調光器は灯体の中や舞台袖に
- はなれたばしょから操作したい
- 1本ずつ配線すると線がたばになる

{::wait/}

そこで共通規格 **DMX512**

# DMX512

**D**igital **M**ultiple**x**

- 512chの調光データを1本の線に多重化
- 40年まえにつくられた規格
- いまも世界中の舞台・ライブハウスの共通語

# デイジーチェーン

```p5_setup
boxes = ["Console", "Fixture", "Fixture", "Fixture"]
addrs = [nil, "Addr 1", "Addr 14", "Addr 27"]
bw = 110
bh = 48
gap = 40
total_w = boxes.size * bw + (boxes.size - 1) * gap
sx = 320 - total_w / 2
sy = 210
```

```p5
p5.text_font(DVI::Graphics::FONT_OUTFIT_18)
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
```

数珠つなぎ + 各灯体にアドレスを設定

# RS485

いちばん下、電気の層

- 2本の線の電圧差で信号をあらわす(差動伝送)
- ノイズに強い: 2本ともずれるので差はこわれない
- 1200mまで、32台まで
- 枯れた、信頼性の高い規格

# UART

RS485の上は、UARTとおなじフレーム形式

```
| start |  b0 b1 b2 b3 b4 b5 b6 b7  | stop | stop |
  1 bit          8 bit                  2 bit
```

- 250kbps / 8N2
- 1バイト = 11ビット = **44マイクロ秒**

{::wait/}

つまりDMXは……
**ただの250kbpsのUART**
マイコンでそのまましゃべれる!

# DMXパケット

```p5_setup
cells = ["BREAK", "MAB", "SC", "1", "2", "3", "...", "512"]
widths = [80, 52, 44, 40, 40, 40, 56, 52]
bh = 44
gap = 4
total = gap * (cells.size - 1)
widths.each { |w| total += w }
sx = 320 - total / 2
sy = 210
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
    p5.stroke(0x92)
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

- BREAK = わざとつくる合図 (Lowを88us以上)
- あとはUARTフレームが513個ならぶだけ

{::wait/}

- ヘッダなし、チェックサムなし、ACKなし
- 1パケット約23ms、秒間44回おくりつづける

# ユニバース

512chのひとまとまり = **ユニバース**

- 1本のケーブルで1ユニバース
- ムービングライト1台で13chつかう
- たりなければユニバースを増やす

# 13ch ムービングライト

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

- ch6に255を書けば全開で点灯
- ch8は12なら赤、28なら青
- 2台目はアドレス14から

# OSI参照モデルにあてはめると

- 物理層: RS485
- データリンク層: DMXパケット
- アプリケーション層: チャンネルの割り当て

{::wait/}

**あいだの層は、なにもない**

そのかわり秒間40回おくりつづける
この割り切りがRubyでも参加できる低いしきい

# パケットを送信する

- Raspberry Pi Pico 2 (RP2350)
- M5Stack DMXユニット
  - 絶縁型RS485トランシーバー
  - マイコンからみるとただのUART

# RubyでDMXを送る

```ruby
uart = UART.new(unit: :RP2040_UART1,
                txd_pin: 20, rxd_pin: 21,
                baudrate: 250_000, stop_bits: 2)

universe = "\x00" * 513   # スタートコード + 512ch
universe[6] = 255.chr     # ch6 = ディマー全開

loop do
  uart.break              # パケットのはじまりの合図
  uart.write universe
end
```

# デモ

灯体を点ける

# 問題: Rubyがとまる

- UART送信はブロッキング
- 1パケット23ms、CPUのほとんどが送信に
- 音もならしたいし、画面も描きたい

{::wait/}

送信をCにきりだそう → **picoruby-dmx**

# picoruby-dmx

- Cがわに513バイトのユニバースバッファ
- タイマー + DMAが秒間40回おくりつづける
- Rubyは値を書くだけ、ブロックしない

```ruby
DMX.init
DMX.start        # バックグラウンド送信開始
DMX.set(6, 255)  # Rubyはチャンネルに書くだけ
```

# デッドマンスイッチ

じつは灯体は、信号がとまっても**消えない**
最後の値のまま固まる

{::wait/}

Rubyがハングすると、だれにも消せない照明が……

{::wait/}

- Rubyが keepalive をよびつづける
- とまったらエンジンが自動でブラックアウト

# 実践: Harucom

趣味でつくっている自作コンピュータ

- RP2350 + DVI出力 + USBキーボード
- PicoRubyベースの自作OS
- エディタもシェルもRuby
- このスライドもRuby (PicoRabbit)

ここに照明コントローラをつくっていく

# コンソールをつくる

チャンネル番号をなまで書きたくない

```ruby
patch.add(:s1, SHEHDS_SPOT_80W_13CH, base: 1)
patch.add(:s2, SHEHDS_SPOT_80W_13CH, base: 14)
patch.group(:all, :s1, :s2)
```

```ruby
dmx(:s1).pan(0.5).tilt(0.2)  # 0.0-1.0に正規化
dmx(:all).dimmer(1.0)        # グループにまとめて
dmx(:s1).color(:red)         # 色は名前で
```

# デモ

ユニバース表示 + コンソール

# 円運動

パンにcos、チルトにsinをわたすだけ

```ruby
t = 0.0
loop do
  dmx(:s1).pan(0.5 + 0.15 * Math.cos(t))
          .tilt(0.4 + 0.15 * Math.sin(t))
  t += 0.05
  sleep_ms 20
end
```

# x = cos, y = sin

```p5
t = DVI.frame_count * 0.03
cx = 320
cy = 250
r = 80
p5.no_fill
p5.stroke(0x49)
p5.stroke_weight(2)
p5.circle(cx, cy, r * 2)
x = cx + r * Math.cos(t)
y = cy + r * Math.sin(t)
p5.no_stroke
p5.fill(0xE0)
p5.circle(x.to_i, y.to_i, 20)
```

高校数学の円のパラメータ表示、そのまま

# シーケンサーをつくる

つぎは時間軸、音楽とあわせたい

- Rubyは「何を・いつ」を決めるだけ
- 発火はハードウェアにまかせる (schedule-ahead)
- GCでとまってもタイミングはくずれない

```ruby
seq(:bd, [1, 0, 0, 0])                    # 4つ打ち
dmx_seq(:all, :dimmer, [255, 0, 128, 0])  # おなじ拍で明滅
```

# Strudel-rb

TidalCycles → Strudel (JS) → **strudel-rb** (asonas)

Pattern = 時間の区間をわたすと
イベントの一覧をかえす関数

```ruby
sound("bd ~ sd ~")                        # ミニ記法
sound("bd*4, hh*8")                       # かさねる
sound("bd*4").every(4) { |p| p.fast(2) }  # 4サイクルごとに倍速
```

{::wait/}

fast/slow/every は「時間の変換」
→ なかみは音でなくてもいい

# 序破急 Johakyu

strudel-rb互換のパターンエンジンをPicoRubyに実装
ひとつのパターンで音とDMXを駆動する

- 序: しずかなたちあがり
- 破: 展開
- 急: クライマックス

{::wait/}

この会館の舞台は、能舞台です

# 音と光をおなじtrackに

```ruby
tempo 120

track(:drums) { sound("bd*4, ~ sd ~ sd, hh*8") }
track(:orbit) { ha("circle", on: :s1, slow: 8) }
track(:pulse) { ha("color_beat",
                   colors: "<red blue yellow>") }
```

ぜんぶ、ひとつのクロック、ひとつのPatternの上に

# ha("circle") のなかみ

```ruby
pan(cosine.range(0.35, 0.65).slow(8))   # パンはcos
tilt(sine.range(0.25, 0.55).slow(8))    # チルトはsin
```

チルトだけ fast(2) にすると……

```p5
cx = 320
cy = 300
rx = 110
ry = 60
p5.stroke(0x49)
p5.stroke_weight(2)
i = 0
n = 72
while i < n
  a1 = i * 2.0 * Math::PI / n
  a2 = (i + 1) * 2.0 * Math::PI / n
  x1 = cx + rx * Math.cos(a1)
  y1 = cy + ry * Math.sin(2 * a1)
  x2 = cx + rx * Math.cos(a2)
  y2 = cy + ry * Math.sin(2 * a2)
  p5.line(x1.to_i, y1.to_i, x2.to_i, y2.to_i)
  i += 1
end
t = DVI.frame_count * 0.03
p5.no_stroke
p5.fill(0xE0)
dx = cx + rx * Math.cos(t)
dy = cy + ry * Math.sin(2 * t)
p5.circle(dx.to_i, dy.to_i, 20)
```

# デモ

序破急でひと演目

序 → 破 → 急

# まとめ

- 照明のうらがわは枯れた技術のつみかさね
  - トライアック / PWM / RS485 / UART / DMX
- 割り切りのおかげで、Rubyでも参加できた
- 照らす技術をRubyで照らしてみました

{::wait/}

つぎにライブにいったら
うしろの機材ブースをみてください
**512個の数字が、秒間40回、とんでいます**

# ご清聴ありがとうございました

GitHub:
- harukasan/harucom-os (PR #17: Johakyu)

Social:
- X: @harukasan
- https://harukasan.dev/
