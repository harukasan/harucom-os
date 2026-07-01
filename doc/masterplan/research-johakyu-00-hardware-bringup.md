# research 00: ハードウェア・通信ブリングアップ (M0, M1)

## 目的

DMX を 1 本でも光らせる前に、Grove(J5) の電気特性と M5 DMX Unit の挙動を実機で確かめ、
「UART 250k で DMX512 が灯体に通る」ことを最小構成で実証する。ここが全ての前提であり、
最大の不確実性 (Grove は本来 I2C 用配線) を最初に潰す。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)
- 必要機材: M5 DMX Unit (CA-IS3092W)、ムービングライト最低 1 台、Grove ケーブル、
  オシロまたはロジックアナライザ、(あれば) DMX テスタ。
- 既存 `picoruby-uart` が使えること (`UART.new`, `write`, `break`)。

## 対象マイルストーン

- M0: リスク先行調査 (電気・通信)。完了条件 = TX 電圧/BREAK/プルアップ/DE 方向の可否判定。
- M1: UART→DMX ブリングアップ。完了条件 = 既存 picoruby-uart で 250k/8N2 + `uart.break(1)`
  + blocking write により、灯体 1 台の dimmer が変化する。

## 設計詳細

### 配線

| Harucom Grove(J5) | M5 DMX Unit (PORT.C) |
|---|---|
| GPIO20 = SDA → UART1 TX | 黄 = UART_RX |
| GPIO21 = SCL ← UART1 RX | 白 = UART_TX (受信は任意) |
| 5V | 赤 = 5V |
| GND | 黒 = GND |

ホストの TX (GPIO20) がユニットの UART_RX (黄) に入る。DMX 出力 (送信専用) ではホスト TX
だけ使う。

### DMX512 フレーム (ホストが生成)

- 250000 baud / 8 データビット / パリティなし / 2 ストップビット (8N2)。
- フレーム = BREAK (≥88µs, Low) + MAB (Mark After Break, ≥8µs, High) + start code (0x00)
  + 最大 512 データスロット。
- M1 のブリングアップは既存 `picoruby-uart` で十分:
  - `uart = UART.new(unit: :RP2040_UART1, txd_pin: 20, rxd_pin: 21, baudrate: 250000,
    data_bits: 8, stop_bits: 2, parity: UART::PARITY_NONE)`
  - 1 フレーム = `uart.break(1)` (1ms BREAK) → `uart.write(frame)` (frame[0]=0x00,
    以降が ch 値) → 適当な間隔で繰り返す。
  - `UART_break` は `uart_set_break(true); sleep_ms(interval); uart_set_break(false)` で
    ms 粒度。1ms BREAK は規格上長めだが多くの灯体が許容する (R2 で確認)。

### 既知のコード事実

- `lib/picoruby/mrbgems/picoruby-uart/ports/rp2040/uart.c`: `UART_break`, `UART_init`,
  `UART_set_baudrate`, `UART_set_format`, `UART_write_blocking`。
- RP2350 GPIO20 = UART1 TX(F2) / GPIO21 = UART1 RX(F2)。
- M5 DMX Unit は esp_dmx 依存 = DMX 生成はホスト側、ユニットは絶縁 RS-485 トランシーバ。
- **確認済み: I2C0/GPIO20-21 は他で未使用**。定義は `include/boards/harucom_board.h` の
  `PICO_DEFAULT_I2C=0`(SDA20/SCL21)だけで、mrbgems/rootfs/src のどこも I2C0 を使っていない →
  UART1 への転用は競合なし。pico-sdk の default-I2C 系を呼ばないよう注意するだけでよい。
- **絶縁はユニット側 (5kVrms)**。XLR/RS-485 側は Harucom と電気的に隔離され、灯体の電源ドメインから
  Harucom 側は保護される (安全上プラス)。要確認は給電のみ (R18)。

## 回路図による机上確認 (オシロ前に完了)

オシロを当てる前に Harucom ボードと M5 ユニットの回路図で確認した結果。R1/R3/R4 は机上で
ほぼ解決し、M0 のオシロ作業は「BREAK を含むフレームの差動波形を 1 回撮る」だけに縮小できた。

参照:
- Harucom ボード回路図 (KiCad): `harukasan/harucom-board` の `connectors.kicad_sch` /
  `usb_power.kicad_sch`。
- M5 ユニット回路図 (PNG): https://static-cdn.m5stack.com/resource/docs/products/unit/Unit-DMX/img-a9577c01-030e-414c-a485-a37d14fa26b1.png
- CA-IS3092W データシート: https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/docs/products/unit/Unit-DMX/CA-IS3092W.pdf

### Harucom ボード側 (確定値)

- Grove(J5) = I2C0。R44/R45 = 4.7k プルアップ → +3V3、R49/R48 = 100Ω 直列 (SDA=GPIO20 /
  SCL=GPIO21)、C31 = 100n。J5: 1=SCL, 2=SDA, 3=+5V, 4=GND。
- 5V 経路 = USB-C(J1, GT-USB-7010ASV) → VBUS → **Polyfuse F1 (SMD1206-100/06N, ホールド
  ≈1.0A / トリップ ≈2.0A)** → +5V → J5 pin3。3.3V は別系統 (U2 = AMS1117-3.3, 1A LDO)。
- Harucom 側は 3.3V ロジックで GPIO20 を push-pull 駆動する。

### M5 ユニット側 (回路図で判明)

- 電源: Grove 5V → **U2 = ME6206A33XG (5V→3.3V LDO)** でユニット内 3V3 を生成。
- **CA-IS3092W のロジック側 VDDA = 3V3** (上記 LDO)。バス側 VISO = ISO_3V3 (絶縁 DC-DC,
  5kVrms)。
- Grove RXD/TXD は **2N7002W ×2 + 3V3 プルアップ (R1/R2 100K, R3 4.7K)** のレベルシフト/
  方向制御を経て DI/RO/DE/RE# に接続。**Grove に DE 線は無く、DE/RE# は UART ラインから基板上で
  自動生成**される (ホスト GPIO 不要)。
- バス側: A/B → 保護ダイオード (D1-D3)、**120Ω 終端を SW1 (SS-1260) で投入**、P1 = XLR-3
  (pin1=ISO_GND, A→pin3, B→pin2)。

## 調査項目

### R1: 3.3V TX をユニットが H と認識するか (影響: 高 → 机上で解決)

**解決 (回路図)**: ユニット入力は 3.3V ロジック (ME6206A33XG で 3V3、入力は 3V3 プルアップ +
2N7002W)。CA-IS3092W VDDA も 3V3。Harucom の 3.3V TX は完全に整合し、**レベルシフタは不要**。

- 残確認: M1/M2 の差動波形観測で、論理が正しく反転して出ることをついでに確認するだけでよい。

### R2: `uart.break` (ms 粒度) で DMX BREAK が灯体に通るか (影響: 中)

- 検証: M1 で `uart.break(1)` + blocking 送信し 1 台が反応するか。通れば最速ブリングアップ
  成立。
- 本番 (M2) は state machine で 176µs に最適化する。

### R3: Grove の 100Ω 直列 + 4.7k プルアップ(3V3) が UART 250k で問題ないか (影響: 高 → 低)

**ほぼ解決 (机上)**: UART TX は push-pull 駆動 (H/L とも能動駆動) なので I2C 用の 4.7k プルアップは
エッジに無関係・無害。直列 100Ω × ケーブル容量の RC は ~数十 ns で 4µs/bit に対し誤差。ユニット
入力も高インピーダンス 3.3V。原理的に問題なし。

- 残確認: M1 の波形でエッジ鈍りが無いことをついでに確認。NG なら (考えにくいが) プルアップ無効化を検討。

### R4: M5 ユニットの DE (方向) 制御の実態 (影響: 高 → 設計上解決)

**設計上解決 (回路図)**: DE/RE# は基板上の 2N7002W 回路で UART ラインから自動生成され、Grove に
DE 線は無い。**ホストの DE GPIO は不要**で、データを送れば送信になる。

- 残確認 (これだけオシロ): **DMX BREAK (長い Low) の間も自動方向制御が送信を保持するか**。
  自動方向回路は通常 Low 駆動中 DE を保持するので問題ないはずだが、A/B 差動出力をフレーム全体
  (BREAK→MAB→データ→ストップビット) で観測し、送信が途切れ/フロートしないことを確認する。
- NG 時 (BREAK 中に DE が落ちる等): BREAK を `uart_set_break` でなく低ボーレートでの 0x00 送出に
  変える (DE がデータとして保持されやすい)、もしくは送信間の保持時間を確認。

### R5 (計測のみ): UART TX blocking が Core0 を何 ms 止めるか (影響: 高)

- 検証: blocking 版で `Machine.board_millis` 前後差を計測。160ch≈7ms / 512ch≈23ms の想定を
  実測で確認。数 ms 超なら DMA 化 (research 01) が必須と確定する。
- ここでは判断材料の計測のみ。DMA 実装は M2/research 01。

### R13 (初期): デイジーチェーン終端 / 反射 (影響: 中)

- M1 段階では 1 台直結なので深追いしない。終端 120Ω スイッチの位置だけ確認しておく。
- 本格的な多灯チェーンは research 03 / 07。

### R18: M5 DMX ユニットの 5V 消費電流 vs Grove 給電能力 (影響: 中 → 低)

**ほぼ問題なし (机上)**: ユニットは小型 LDO (ME6206A33XG) + 絶縁 DC-DC で消費は控えめ。ボードの
VBUS は F1 (≈1.0A ホールド) で保護され、十分なはず。ただし VBUS 1.0A は 3.3V系 + USB ホスト
(キーボード) + Grove 5V の合計で共有する点に留意。

- 残確認: ユニット動作時に 5V の電圧降下や不安定が無いことを確認 (簡易)。NG 時はユニットを別電源
  (外部 5V) で給電し、信号 GND だけ Grove と共通にする。
- 灯体本体は別電源 (主電源) なので Grove 給電対象はユニットのみ。

## 受け入れ条件 (DoD)

- 回路図机上確認で R1/R3/R4/R18 が解決済み (本ファイル上段)。レベルシフタ・DE GPIO は不要と確定。
- **オシロは「BREAK を含むフレームの差動波形を 1 回撮る」だけ**: A/B 差動が BREAK→MAB→データ→
  ストップビットを通して途切れず出ること (R4 の BREAK 保持)、エッジ鈍りが無いこと (R3)、論理が
  正しいこと (R1)、BREAK が灯体に通ること (R2) をこの 1 観測でまとめて確認。
- `uart.break(1)` + blocking write で灯体 1 台の dimmer ch が 0→255 で点灯/変化する (M1 完了)。
- R5 の blocking 時間が実測され、DMA 化要否が数値で確定している。
- R18: ユニットが Grove 5V で安定動作する (or 別電源が要る) ことが確認済み。

## 触るファイル

- 確認用の使い捨てスクリプト (例 `rootfs/app/dmx_uart_probe.rb`、IRB から実行)。本実装では
  なく波形確認・点灯確認用。
- 参照: `lib/picoruby/mrbgems/picoruby-uart/ports/rp2040/uart.c`、
  `include/boards/harucom_board.h`。

## 次のハンドオフ先

- R5 で DMA 化が必要と確定 → [research-johakyu-01-dmx-engine.md](research-johakyu-01-dmx-engine.md) (M2)。
- 灯体が複数揃い次第 → [research-johakyu-03-fixtures.md](research-johakyu-03-fixtures.md) (M3)。
