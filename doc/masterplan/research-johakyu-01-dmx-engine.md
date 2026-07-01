# research 01: DMX 背景送信エンジン `picoruby-dmx` (M2, M2c)

## 目的

512 バイトのユニバースを 40Hz で連続送信し続ける背景エンジンを C で作る。Ruby は値を
更新するだけで、送信タイミングはハードウェア (DMA + タイマー) が保証する。これにより
mruby の GC/スケジューラジッタから DMX リフレッシュを切り離す。

**pwm-audio とは別物の「フレーム化プロトコルエンジン」**である点に注意。DMX は BREAK + MAB +
start code + N バイトを 40Hz で反復するフレーム送信で、pwm-audio のような連続サンプル
ストリームではない。BREAK はデータバイトではなく「線を長く Low に保つ特殊状態」で DMA では
なくアラーム state machine が要る。ユニバースは固定 513B をその場で上書きするだけで、
リングバッファも生産者/消費者も無い。pwm-audio と共有するのは「背景でハードウェアが送り続け、
Ruby は値を更新するだけ」という一般原則のみ。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、
  [research-johakyu-00-hardware-bringup.md](research-johakyu-00-hardware-bringup.md)
- M1 完了 (UART で灯体 1 台が点灯)、R5 の blocking 時間計測済み (DMA 化判断の根拠)。
- mrbgem 構造の理解 (CLAUDE.md の mrbgem structure)。

## 対象マイルストーン

- M2: `picoruby-dmx` 背景送信エンジン。完了条件 = state machine + DMA ch3 で 512B が
  40Hz 連続送信、Core0 ブロックなし。
- M2c: 機能確認 (単体)。完了条件 = `rootfs/app/dmx_check.rb` で下記チェックリスト全項目を
  実機/DMX テスタ/ロジアナで確認。

## 設計詳細

### mrbgem レイアウト

```
mrbgems/picoruby-dmx/
  mrbgem.rake               # spec のみ (picoruby-pwm-audio と同型)
  include/dmx.h             # 公開 C API (pico-sdk 非依存)
  src/dmx.c                 # 非依存部 + #include "mruby/dmx.c"
  src/mruby/dmx.c           # mruby binding (DMX モジュール)
  ports/rp2350/dmx_port.c   # UART1 + BREAK state machine + DMA
```

### ユニバースバッファ (C 保持、Ruby は値更新のみ)

```c
/* dmx.h */
#define DMX_SLOTS 512
extern volatile uint8_t dmx_universe[1 + DMX_SLOTS]; /* [0]=start code(0x00), [1..512]=data */
extern volatile uint16_t dmx_active_slots;           /* 短縮送信するスロット数 */

void dmx_init(void);                                  /* UART1 250000 8N2, GPIO20/21, DMA claim */
void dmx_set(uint16_t ch, uint8_t v);                 /* ch: 1-512 */
void dmx_set_range(uint16_t ch, const uint8_t *vals, uint16_t n);
void dmx_blackout(void);
void dmx_start(void);
void dmx_stop(void);
void dmx_set_active_slots(uint16_t n);
uint32_t dmx_frame_count(void);
void dmx_keepalive(void);             /* Ruby が定期的に呼ぶ heartbeat */
void dmx_set_deadman_ms(uint32_t ms); /* 0=無効。既定 500ms 程度 */
```

### 送信エンジン (`dmx_port.c`) — state machine + DMA

初期化:
- `uart_init(uart1, 250000)`, `uart_set_format(uart1, 8, 2, UART_PARITY_NONE)`,
  `gpio_set_function(20, GPIO_FUNC_UART)`。
- DMA ch3 を UART1 TX へ: `channel_config_set_dreq(&c, DREQ_UART1_TX)`,
  read=`dmx_universe`, write=`&uart1_hw->dr`, 8bit, read_increment=true,
  write_increment=false。チャネルは `dma_claim_unused_channel` で動的取得 (R11)。

専用 `alarm_pool` (Alarm 0/1 を避け 2 または 3) で 40Hz (25ms) リピートタイマー。
コールバックがフレーム state machine を起動:

1. `uart_set_break(uart1, true)` (TX Low 開始) → 176µs の one-shot alarm 予約 (≥88µs に余裕)。
2. break false (MAB 開始、High) → 12µs one-shot。
3. `dma_channel_set_read_addr(ch3, dmx_universe, false)`,
   `set_trans_count(ch3, 1 + dmx_active_slots, true)` で DMA キック。以降 CPU 関与なしで
   FIFO へ流れる。
4. 次フレーム前に `dma_channel_is_busy` をガードチェック (R12)。

これにより `uart_write_blocking` を排除し、Core0 を止めない。BREAK は `uart_set_break`
(手法 a) で生成し、DMA はデータ部のみ担当する (ボーレート変更による BREAK 手法は DMA と
両立しないため使わない)。

### keepalive デッドマン (R19, 必須)

灯体は DMX 信号断で自動消灯しない (最後の値で固まる)。VM がハング/クラッシュしても消灯できる
ように、エンジン側に dead-man を持たせる。

- Ruby はメインループ毎に `DMX.keepalive` を呼び、最終 heartbeat 時刻 (`board_millis`) を更新。
- 40Hz フレームのアラームコールバックで「現在時刻 − 最終 heartbeat > deadman_ms (既定 ~500ms)」
  を検出したら、エンジンが自動でユニバースをゼロにして送出 (Ruby に依存せず消灯)。
- 起動直後 (`dmx_init`/`dmx_start`) にもゼロフレームを送り、前回固まった状態を消す。
- VM が復帰して `keepalive` が再開すれば通常送信に戻る。これはハードウェア (アラーム) 側で
  完結するので、mruby が止まっていても効く。

### Ruby API (`src/mruby/dmx.c` + `rootfs/lib/board/dmx.rb`)

```ruby
DMX.init                        # GPIO20/21, 250k 8N2, DMA 設定
DMX.start                       # 背景 40Hz 送信開始
DMX.set(ch, val)                # ch 1-512, val 0-255
DMX.set_range(ch, [r, g, b])    # 連続書き込み
DMX.active_slots = 160          # 使用 ch 数まで短縮 (リフレッシュ高速化)
DMX.blackout
DMX.frame_count                 # デバッグ表示用
DMX.get(ch)                     # UI 用読み出し
DMX.keepalive                   # メインループ毎に呼ぶ heartbeat (dead-man)
DMX.deadman_ms = 500            # heartbeat 断でゼロ送出するまでの猶予 (0=無効)
```

### CMake / build_config 配線

- `CMakeLists.txt`: `picoruby-pwm-audio` ブロック (L129-137) を複製して
  `add_library(picoruby-dmx ... src/dmx.c ports/rp2350/dmx_port.c)`,
  `target_link_libraries(picoruby-dmx pico_stdlib hardware_uart hardware_dma hardware_pwm pico_time)`,
  `target_include_directories(... mrbgems/picoruby-dmx/include)`。`harucom_os` の link
  (L232-247) と include に `picoruby-dmx` を追加。
- `build_config/harucom-os-pico2.rb`: gem 登録。
- 新規 `MRB_SYM()` を追加するため、ビルド前に `rake distclean` が必要。

## 調査項目

### R5: UART TX blocking → DMA 化の確定 (影響: 高)

research 00 の計測で blocking が数 ms 超なら DMA 必須。本マイルストーンは DMA 前提で実装。
DMA 中に Core0 が他処理 (Scheduler/UI/Audio 充填) を回せることを確認する。

### R11: DMA チャネル枯渇 / 衝突 (影響: 低)

DVI が ch0/ch1 + `DMA_IRQ_1` を専有。オーディオ ch2、DMX ch3 (+ctrl ch4) を新規 claim。

- 検証: `dma_claim_unused_channel` で動的取得し起動ログ出力。DVI 起動後に claim されること、
  DMX/オーディオの完了 IRQ が `DMA_IRQ_0` で DVI の `DMA_IRQ_1` と干渉しないことを確認。

### R12: 40Hz 周期 vs データ長の衝突 (影響: 中)

active_slots を増やすとフレーム長が周期に迫り、前フレーム DMA 未完了で次 BREAK に入る恐れ。

- 検証: `dma_channel_is_busy` ガード + active_slots に応じた可変周期。全 512ch (≈23ms) でも
  破綻しないこと、最悪 33ms (30Hz) へ自動降格すること。

### R19: 灯体が信号断で自動消灯しない → dead-man 必須 (影響: 高)

灯体は最後の値で固まる (実機で確認済みの前提)。エンジン側 keepalive デッドマンで消灯を保証する。

- 検証: `DMX.start` 後に `keepalive` を止め (Ruby ループを意図的に停止/例外)、deadman_ms 経過で
  灯体が消灯することを確認。`keepalive` 再開で通常送信へ復帰すること。起動直後のゼロフレームで
  前回の固まり状態が消えること。
- 関連: アプリの異常時ブラックアウトとウォッチドッグ復帰は research 06/07。

## M2c 機能確認チェックリスト (`rootfs/app/dmx_check.rb`)

DSL に依存せず C API を直接叩く確認ハーネス (`audio_demo.rb` 方式)。恒久スモークテストとして
残す。

- `DMX.init` が成功し UART1 250k/8N2 が GPIO20 に出る (オシロ/ロジアナ)。
- `DMX.start` で背景リフレッシュ開始、`DMX.frame_count` が増加 (40Hz 前後)。
- フレーム波形: BREAK≥88µs / MAB≥8µs / 250kbaud / start code 0x00 / 各スロット値を
  ロジアナで確認。
- `DMX.set(ch, val)` / `DMX.set_range(ch, [...])`: 灯体または DMX テスタで指定値が反映
  (例 ch1 dimmer を 0→255 ランプ、複数 ch チェイス)。
- `DMX.active_slots=` 変更でフレーム長が変わり、リフレッシュ周波数が上がる (`frame_count` 計測)。
- `DMX.blackout` で全 ch 0。
- 背景送信中に Core0 が固まらない (画面カウンタ更新やキーボード応答が維持される)。
- `dma_channel_is_busy` ガードでフレーム衝突なし (全 512ch 送信時も破綻しない)。
- `keepalive` を止めると deadman_ms 後に灯体が消灯し、再開で復帰する (R19)。

## 受け入れ条件 (DoD)

- M2: 512B ユニバースが 40Hz で連続送信され、Ruby から `DMX.set` で値が反映され、送信中も
  Core0 が他処理を回せる。
- M2c: 上記チェックリスト全項目を実機/テスタ/ロジアナで確認済み。`dmx_check.rb` が
  `rootfs/app/` に常駐。

## 触るファイル

- 新規: `mrbgems/picoruby-dmx/{mrbgem.rake,include/dmx.h,src/dmx.c,src/mruby/dmx.c,ports/rp2350/dmx_port.c}`
- 新規: `rootfs/lib/board/dmx.rb`、`rootfs/app/dmx_check.rb`
- 変更: `CMakeLists.txt`、`build_config/harucom-os-pico2.rb`
- 手本: `mrbgems/picoruby-pwm-audio/ports/rp2350/pwm_audio_port.c`、
  `lib/picoruby/mrbgems/picoruby-uart/ports/rp2040/uart.c`

## 次のハンドオフ先

- [research-johakyu-03-fixtures.md](research-johakyu-03-fixtures.md) (M3: フィクスチャモデル)。
- DMA バンク・クロックの整合は [research-johakyu-02-audio-engine.md](research-johakyu-02-audio-engine.md) と合わせて確認。
