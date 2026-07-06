# 序破急 (Jo-ha-kyū) マスタープラン

関西Ruby会議のデモとして、Harucom の Grove(J5) に接続した M5Stack DMX Unit
(CA-IS3092W, UART→絶縁RS-485) 経由で、デイジーチェーン接続したムービングライト
(SHEHDS LED Spot 80W、同一機種 2 台) を DMX512 で制御する。[Strudel](https://strudel.cc/) を参考にした
「リズムボックス兼 DMX 制御 DSL」を Ruby でライブコーディングし、512ch ユニバースを
リアルタイムにデバッグ表示する分割画面エディタで「DMX の仕組み」を見せる。

これは全体像と索引のドキュメント。各マイルストーンの詳細・調査・受け入れ条件は
マイルストーン別の `research-johakyu-NN-*.md` に分割している(下記索引)。新しい
セッションは「この masterplan + 着手するマイルストーンの research ファイル」だけ読めば
作業に入れる。

## プロジェクト名: 序破急 (Jo-ha-kyū)

会場が能舞台であることに由来。序破急は能・雅楽の根本にあるテンポ理論(序=静かな
立ち上がり、破=展開、急=急速なクライマックス)で、音・光・リズムを時間軸で束ねる
本プロジェクトの本質に一致する。

命名:

- DSL/アプリ/ブランド名 = Jo-ha-kyū、コード識別子 `Johakyu`、ローマ字 `johakyu`
- 新規アプリ: `rootfs/app/johakyu.rb`
- 新規 Ruby ライブラリ群: `rootfs/lib/johakyu/`
- トップレベル DSL 名前空間: `Johakyu`
- 低レベル DMX ドライバ gem は記述的な `picoruby-dmx` のまま(`Board::DMX` も維持)

任意拡張として、jo/ha/kyu を「演出のアレンジ区分」に使う(`jo { }` / `ha { }` /
`kyu { }` で各区分のテンポ・強度・ライト密度を宣言し、Scheduler が区分間を遷移して
「静→展開→急」の山場を構築する)。Strudel/Tidal に無い独自要素で、名前を機能として
活かす。

## 確定方針

| 項目 | 決定 |
|---|---|
| DMX I/F | UART1 (GPIO20=TX→ユニット黄/UART_RX, GPIO21=RX) を 250000 baud / 8N2。ホストが DMX512 全体を生成 |
| 音源 | PWM 音源 (3ch) で発音 + サンプリング WAV 再生。タイミング重視のため DMA を使用 |
| DSL | 段階的: ステップシーケンサ → Strudel 風ミニ記法 → パターン演算 (fast/slow/every/rev/euclid) |
| エディタ | 上下分割 (上=ステータス/ユニバース表示、下=エディタ)。`edit.rb` の部品を再利用。保存/キーで即時 eval 反映 |
| 互換基準 | [`asonas/strudel-rb`](https://github.com/asonas/strudel-rb) の基礎部分と互換 |

## ハードウェア構成

| 信号 | 経路 | 備考 |
|---|---|---|
| DMX TX | RP2350 GPIO20 (UART1 TX) → Grove(J5) SDA → M5 DMX Unit 黄 (UART_RX) | 250000 baud / 8N2 |
| DMX RX | GPIO21 (UART1 RX) ← Grove(J5) SCL ← M5 DMX Unit 白 (UART_TX) | 受信は任意 (送信専用運用) |
| 電源 | Grove(J5) 5V / GND | M5 ユニットへ 5V 給電 |
| 音声 | GPIO24/25 (PWM slice 4 A/B) | 既存 PWM オーディオ |

Grove(J5) は本来 I2C0 用 (GPIO20=SDA / GPIO21=SCL、4.7kΩ プルアップ(3V3) + 100Ω
直列)。RP2350 では GPIO20=UART1 TX(F2) / GPIO21=UART1 RX(F2) なので、同じ物理コネクタを
UART として使う。M5 DMX Unit は "dumb" な絶縁 RS-485 トランシーバで、DMX512 プロトコル
(BREAK/MAB/start code/512 スロット) はホスト側 (Harucom) が生成する。

## アーキテクチャ概要

設計原則は「タイミングが要る処理はハードウェアに逃がし、Ruby は何を・いつ鳴らすかを
決めるだけ。実際の発火はハードウェアが時刻どおりに行う」(schedule-ahead)。CPU が限られる
RP2350 で、割り込みやスピンを最小化するのが狙い。

タイミングは **3 つの独立した仕組み** に分かれ、1 つのクロックを共有する。これらを混同しない:

1. **マスタークロック**: 保守 CPU ゼロのフリーランタイマ。Ruby は既存 `Machine.board_millis`
   (ms) を読むだけで足りる (60Hz tick に対し ms 解像度で十分)。音エンジンから疎結合 (音が
   止まってもシーケンサ・DMX は動き続ける)。サブ ms が要る音オンセットのみ `sample_clock` で補う。
2. **オーディオエンジン**: 固定レートのサンプルストリーミング (DMA ペーシング)。ここだけが
   既存 `picoruby-pwm-audio` (背景エンジン + リングバッファ + Ruby 充填) を素直に踏襲する。
3. **DMX エンジン**: フレーム化プロトコル送信 (BREAK + MAB + start code + N バイトを 40Hz で
   反復)。pwm-audio とは別物で、リングバッファも生産者/消費者も無い。固定 513B のユニバースを
   その場で上書きし、DMA + アラーム state machine で再送する独自エンジン。**灯体は DMX 信号断で
   自動消灯しない (最後の値で固まる) ため、VM ハング/クラッシュ時に消灯できる keepalive
   デッドマンを内蔵**する (Ruby が一定時間 heartbeat を更新しなければエンジンが自動でゼロ送出)。

pwm-audio は「オーディオエンジンの手本」であって、タイミング全般の万能テンプレートではない。
共有する一般原則は「背景でハードウェアが出力し続け、Ruby は値を更新するだけ」という点のみ。

### Core 割り当て (既存踏襲・不変)

- Core 0: mruby VM / USB host / keyboard / オーディオ充填 / DMX 値更新 / シーケンサ
- Core 1: DVI 出力専用 (`BASEPRI=0x20`, `DMA_IRQ_1` のみ)。触らない

### 割り込み / DMA / タイマー資源

| 資源 | 用途 |
|---|---|
| Timer Alarm 0 | mruby task tick (1ms) ※既存 |
| Timer Alarm 1 | PWM オーディオ ISR ※既存 (DMA 化で役割変更) |
| DMA ch0/ch1 + `DMA_IRQ_1` | DVI (Core1) ※既存・専有 |
| DMA ch2 | オーディオ (リングバッファ → PWM slice4 CC, `DREQ_DMA_TIMER0` 22050Hz) ※新規 |
| DMA ch3 (+ctrl ch4) | DMX (ユニバース → UART1 TX FIFO, `DREQ_UART1_TX`) ※新規 |
| `DMA_IRQ_0` | オーディオ/DMX の DMA 完了 IRQ ※新規 (DVI の `DMA_IRQ_1` とバンク分離) |
| Timer Alarm 2/3 + 専用 alarm pool | DMX フレーム state machine (BREAK→MAB→DMA) ※新規 |

DMA バンク分離 (新規完了 IRQ は必ず `DMA_IRQ_0`) と、Alarm 0/1 を避けた Alarm 2/3 使用が
安全の鍵。

### クロック源と schedule-ahead (タイミング設計の核)

マスタークロックは **フリーランタイマ**。Ruby は既存の `Machine.board_millis` (ms) を読むだけで
よい (60Hz tick・40Hz DMX に対し ms 解像度で十分。新規バインドや distclean は不要)。常時稼働で
保守 CPU はゼロ、音エンジンに依存しないので、音を止めても/アンダーランしても DMX 演出は動き
続ける (本番で堅い)。`Clock` は小さな抽象にして差し替え可能にし、既定をこの ms タイマ実装に
する (将来サブ ms クロックが要れば `time_us_64` の µs バインドや音サンプルカウンタ実装へ交換可)。

Ruby は `Clock.position` (= 経過 ms / cycle 長から算出するサイクル位置) を読むだけ。GC で
数 ms 止まっても復帰時に読めば過ぎた区間をまとめて処理できる。

**schedule-ahead**: Scheduler は低レート (例 60Hz = DVI フレーム毎) で `[last, now + lookahead)`
を query し、各離散オンセットの **正確な発火時刻** を計算してエンジンに渡す。実際の発火は
ハードウェアが時刻どおりに行うため、Ruby の tick を上げなくてもタイミング精度が出る
(mruby の query/GC 負荷を抑えられる)。

- 音オンセット: `Audio.sample_clock` (音 DMA が刻むサンプル位置) を使い、目標時刻を **サンプル
  オフセット** に変換して C エンジンへ予約 → サンプル精度で発音。`sample_clock` はマスター
  クロックではなく、この「音の遅延補正・サンプル精度予約」専用に使う。
- DMX: 出力は 40Hz フレームに量子化されるので、目標時刻を含むフレームの前にユニバース値を
  書けば足りる。
- 光と音の整合: lookahead を「音バッファ遅延と 1 DMX フレームの最大」以上に取れば、音と光は
  同じ目標時刻に揃う (固定遅延補正)。

参考に [`asonas/strudel-rb`](https://github.com/asonas/strudel-rb) は `Scheduler::Cyclist` で
音サンプル数からサイクルを進める (音=クロック)。Johakyu は音合成を C が担い Ruby はクロックを
読むだけなので、クロックを音から切り離し、独立タイマを基準にできる。

```
                       ┌──────────── Core 0 (mruby) ─────────────┐
 USB kbd task          │  app/johakyu.rb (live coding loop)      │
 keyboard task         │   - 編集: Editor::Buffer + RubySyntax   │
                       │   - 保存/F5: Sandbox 差し替え(量子化)   │
                       │   - Scheduler.tick(Clock.position)  │    │
                       │       [schedule-ahead, ~60Hz]       │    │
                       │       active Pattern を query        │    │
                       │       → Audio 予約(sample offset)    │    │
                       │       → DMX.set (universe 上書き)    │    │
                       │   - Audio.update (ringbuf 充填)      │    │
                       │   - DVI.wait_vsync → UI 再描画 ──────┼─┐  │
                       └─────────────────────────────────────┼─┼──┘
   HW timer (board_millis) ──► Clock.position (master)        │ │
   DMA ch2 (DREQ_TIMER0 22050Hz) ──► sample_clock(音予約用)──┘ │
        │                  → PWM slice4 (GPIO24/25 音声出力)      │
        │                                                        │
   DMX ユニバース(C, 513B) ── Alarm2/3 state machine:            │
        ▲ Ruby: DMX.set      BREAK→MAB→DMA ch3(DREQ_UART1_TX)    │
        │                    → UART1 TX GPIO20 → M5 DMX Unit      │
   ┌────┴───────────────── Core 1 (DVI, 不可侵) ─────────────────┘
   │  DMA ch0/ch1 + DMA_IRQ_1, BASEPRI=0x20, 640x480 60FPS
```

## コンポーネント一覧

### C で新規実装: mrbgem `picoruby-dmx`

| ファイル | 内容 |
|---|---|
| `mrbgems/picoruby-dmx/mrbgem.rake` | spec のみ (`picoruby-pwm-audio/mrbgem.rake` と同型) |
| `mrbgems/picoruby-dmx/include/dmx.h` | 公開 C API (pico-sdk 非依存)。ユニバースバッファ宣言、set/start 等 |
| `mrbgems/picoruby-dmx/src/dmx.c` | プラットフォーム非依存部 (バッファ操作)。`src/mruby/dmx.c` を include |
| `mrbgems/picoruby-dmx/src/mruby/dmx.c` | mruby binding (`DMX` モジュール) |
| `mrbgems/picoruby-dmx/ports/rp2350/dmx_port.c` | UART1 250k/8N2 初期化、BREAK 生成 state machine、DMA 送信、40Hz リフレッシュ |

CMake 配線は `picoruby-pwm-audio` ブロック (`CMakeLists.txt` L129-137) を複製し
`hardware_uart hardware_dma hardware_pwm` をリンク。`harucom_os` の link/include に追加
(L232-247)。build_config (`build_config/harucom-os-pico2.rb`) に gem 登録。

詳細は [research-johakyu-01-dmx-engine.md](research-johakyu-01-dmx-engine.md)。

### C で既存拡張: `picoruby-pwm-audio`

| ファイル | 変更 |
|---|---|
| `include/pwm_audio.h` | PCM ch 構造体、`play_pcm`、`sample_clock` 宣言 |
| `src/pwm_audio.c` | `pwm_audio_calc_sample` に PCM レート変換ミックス段を追加。サンプルカウンタ加算 |
| `ports/rp2350/pwm_audio_port.c` | Timer ISR 駆動 → DMA ch2 + pacing timer 駆動へ移行。half-buffer 完了 IRQ (`DMA_IRQ_0`) で充填 |
| `src/mruby/pwm_audio.c` | `PWMAudio.sample_clock` / `play_pcm` / `pcm_stop` を追加 |

`src/pwm_audio.c` の合成・ミックスは不変、`update()` API も維持 (後方互換)。
詳細は [research-johakyu-02-audio-engine.md](research-johakyu-02-audio-engine.md)。

### Ruby で新規実装: `rootfs/lib/johakyu/`

| ファイル | 内容 |
|---|---|
| `pattern.rb` | 統一 Pattern (Hap/TimeSpan/`query_arc`, strudel-rb 互換意味論。fast/slow/rev/every/euclid/struct/segment/range) |
| `mini.rb` | strudel-rb 互換ミニ記法パーサ (mruby 向け手書き) |
| `signal.rb` | saw/sine/tri 連続 signal |
| `fixture.rb` | personality / patch / group |
| `clock.rb` | 差し替え可能 Clock 抽象。既定=フリーランタイマ (`Machine.board_millis`, ms)。`setcps`/`setcpm`/`setbpm` → cycle 長 |
| `scheduler.rb` | tick (schedule-ahead, ~60Hz) / 2 系統ディスパッチ (音=サンプル予約 + DMX=universe 上書き) / 連続 signal サンプリング / track 別 last-good fallback / 量子化差し替え |
| `dsl.rb` | `Johakyu` 名前空間。`sound`/`s`/`note`/`n`/`stack`/`cat` は strudel-rb 互換 + 独自 `dmx`。任意 `jo`/`ha`/`kyu` |
| `wav.rb` | WAV ヘッダ解析 |
| `universe_view.rb` | 512ch 可視化 |

`rootfs/lib/board/dmx.rb` (`Board::DMX` 薄ラッパ、`pwm_audio.rb` と同型) も追加。

### Ruby で新規実装: アプリ

`rootfs/app/johakyu.rb` — 上下分割ライブコーディング UI。
詳細は [research-johakyu-06-editor-ui.md](research-johakyu-06-editor-ui.md)。

### 既存資産の再利用 (修正不要)

| 部品 | 用途 |
|---|---|
| `Editor::Buffer` | コード編集データモデル |
| `RubySyntax` | ハイライト / オートインデント |
| `Console` / `DVI::Text` / `DVI::Graphics` | UI 描画 |
| `Sandbox` | ライブ eval (loop + suspend/resume パターン、`irb.rb` 参照) |
| pwm-audio 合成基盤 | 3ch 合成・pan・vol・soft_clip |
| UART HAL | C API の手本 |

## 光と音の同期 (strudel-rb モデルでの実現)

strudel-rb の実ソース確認により、1 つの Pattern モデルで光と音を同期駆動できることを
確認済み。

1. クロックは独立したフリーランタイマ (上記)。音と DMX は同一クロックを共有する。
2. 1 回の query を 2 つのシンクへ振り分ける。tick (schedule-ahead) ごとに
   `haps = pattern.query_arc(last, now + lookahead)`。Hap の `value` (Hash) を見て、音キー
   (`:s`/`:note`/`:n`) → PWM/WAV エンジン (目標時刻をサンプルオフセットに変換して予約)、
   DMX キー (独自規約 `{dmx:, attr:, value:}`) → ユニバースバッファ、へ振り分ける。同一
   クロックの同一目標時刻で発火するためキックと dimmer は揃う (lookahead で音バッファ遅延を補正)。
3. 離散と連続の両対応。離散 (`has_onset?`) → トリガ (ドラムヒット/色変化/ストロボ)。
   連続 (`sine`/`saw` signal) + `segment(n)`/`range(min,max)` → 毎 tick 現在値を
   サンプリングして DMX レベル ch へ書込み (パン/チルト/ディマーの滑らかな動き)。
4. 同じ変換が音にも光にも効く (`fast/slow/rev/every/euclid` は Pattern 段階で適用)。
5. ライブリロードの堅牢性も流用。strudel-rb の `tracks` は query エラー時に last-good
   へフォールバックし全体を黙らせない。

Johakyu が strudel-rb に足すのは (a) DMX 対応ディスパッチャ (2 系統シンク) と
(b) 連続バインドの毎ブロックサンプリング経路のみ。Pattern/query/Hap コアは無改変で互換を
保つ。音側合成は C が担うため Ruby VM は query とディスパッチのみで、strudel-rb より
mruby に軽い。詳細は
[research-johakyu-04-pattern-core.md](research-johakyu-04-pattern-core.md)。

## 段階的 DSL

常に動く状態を保ち、前段を壊さず積み増す。デモ最低ラインは段階 A (音光同期) で成立。

- 段階 A (ステップ): `seq(:bd,[1,0,0,0])` / `dmx_seq(:smalls,:dimmer,[255,0,128,0])`
- 段階 B (ミニ記法): `sound("bd ~ sn ~")` / `dmx(:smalls).color("red blue red blue")`
- 段階 C (演算 + signal): `sound("bd*4").every(4){|p| p.fast(2)}` /
  `dmx(:smalls).dimmer(saw.segment(16).slow(2))` /
  `dmx(:bigs).pan(sine.range(0.2,0.8).slow(8))`

詳細は [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md)。

## 上下分割 UI

106×37 を上=ステータス/ユニバース表示 (毎フレーム更新)、下=エディタ (フル幅 106 桁) に
分ける。上下にすることでエディタが `edit.rb` をほぼそのまま再利用でき、`RubySyntax`
描画も幅制限なしで使える。値が変化した ch セルを一瞬反転ハイライトし「今どの ch が
動いたか」を見せることで、DMX が ch 番号 × 値の配列であることを直感的に伝える。
詳細は [research-johakyu-06-editor-ui.md](research-johakyu-06-editor-ui.md)。

## マイルストーン

| # | マイルストーン | 完了条件 | 依存 | research |
|---|---|---|---|---|
| M0 | リスク先行調査 | TX 電圧/BREAK/プルアップ/DE 方向の可否判定 | — | 00 |
| M1 | UART→DMX ブリングアップ | 既存 picoruby-uart で 250k/8N2 + `uart.break(1)` + blocking write、灯体1台の dimmer が変化 | M0 | 00 |
| M2 | `picoruby-dmx` 背景送信エンジン | state machine + DMA ch3、512B が 40Hz 連続送信、Core0 ブロックなし | M1 | 01 |
| M2c | picoruby-dmx 機能確認 (単体) | `rootfs/app/dmx_check.rb` でチェックリスト全項目を実機/DMX テスタ/ロジアナで確認 | M2 | 01 |
| M3 | フィクスチャモデル | `dmx(:s1).pan(0.5)` が正しい絶対 ch に解決 | M2c | 03 |
| M4 | Clock + Scheduler + 段階A | タイマクロック基準でステップが音 + 光を駆動 (キックの瞬間に dimmer が立つ)。音は既存 `tone`/`beep` で可 | M3 | 04, 05 |
| M5 | オーディオ WAV + DMA 化 | WAV ワンショット再生 + ジッタ低減 + `audio_demo.rb` 回帰 OK | M0 | 02 |
| M6 | サンプルクロック公開 | `PWMAudio.sample_clock` (単調増加) を Ruby が読める | M5 | 02 |
| M6c | picoruby-pwm-audio 機能確認 (単体) | 拡張 `audio_demo.rb` でチェックリスト全項目を確認 | M6 | 02 |
| M7 | ミニ記法 (段階B) | `sound("bd ~ sn ~")` / `color("red blue")` 動作 | M4 | 05 |
| M8 | パターン演算 + signal (段階C) | fast/slow/every/rev/euclid + `sine.slow` がパン/ディマーに効く | M7 | 05 |
| M9 | 上下分割 UI | 上=ステータス/ユニバース・下=エディタ、コード編集 + ch 表示 + F5 原子差し替え | M3, M4 | 06 |
| M10 | デモ仕上げ | 全 2 台が音と同期して演出、ライブ編集が破綻しない | 全部 | 07 |

M2c / M6c は DSL を待たずに C 層 2 gem を単体検証する関門で、ここを通ってから上位層
(M3 以降 / M4 以降) に進む。

### 依存 DAG

```
M0 ──> M1 ──> M2 ──> M2c ──> M3 ──> M4 ──> M7 ──> M8 ──┐
                                    M3,M4 ──> M9 ───────┼─> M10
M0 ──> M5 ──> M6 ──> M6c ──(音DMA/WAV: 並行・後追い強化)─┘
```

M4 はタイマクロック + 既存発音で成立するため、音 DMA/WAV (M5/M6/M6c) はクリティカルパスから
外れ、並行・後追いの強化になる。sample_clock は M8 以降で音オンセットをサンプル精度化する際に
使う (それまでは tick 粒度の発音で可)。

クリティカルパス: M0 → M1 → M2 → M2c → M3 → M4 → M7 → M8 → M9 → M10。M5/M6/M6c
(オーディオ DMA/WAV 系) はクリティカルパス外の並行・後追い。M4 はタイマクロック (board_millis)
+ 既存発音で成立するので、音 DMA の完了を待たずにコアの音光同期デモへ到達できる。

## research ファイル索引

| ファイル | マイルストーン | 内容 | 担当 R |
|---|---|---|---|
| [00-hardware-bringup](research-johakyu-00-hardware-bringup.md) | M0, M1 | 電気・通信・BREAK・DE 方向、給電、灯体1台点灯 | R1-R5, R13, R18 |
| [01-dmx-engine](research-johakyu-01-dmx-engine.md) | M2, M2c | `picoruby-dmx` + keepalive + 単体確認 | R5, R11, R12, R19 |
| [02-audio-engine](research-johakyu-02-audio-engine.md) | M5, M6, M6c | WAV + DMA + sample_clock + 単体確認 | R7, R8 |
| [03-fixtures](research-johakyu-03-fixtures.md) | M3 | フィクスチャモデル・DMX チャート・アドレス整合 | R6, R13, R14 |
| [04-pattern-core](research-johakyu-04-pattern-core.md) | M4 (土台) | strudel-rb 互換コア + 同期ホストスパイク | R15, R16, R17 |
| [05-dsl-stages](research-johakyu-05-dsl-stages.md) | M4, M7, M8 | 段階的 DSL と DMX 統合 | R15/R17 再評価 |
| [06-editor-ui](research-johakyu-06-editor-ui.md) | M9 | 上下分割 UI・ライブリロード・異常時ブラックアウト | R9, R10, R19 |
| [07-demo](research-johakyu-07-demo.md) | M10 | 統合・演出プリセット・アドレス整合・本番ランブック | R13, R14, R19 |

## リスク一覧 (R1-R19)

各 R の詳細・検証手段は担当 research ファイルに記載。下表はマスター索引。

| # | 論点 | 影響 | 担当 |
|---|---|---|---|
| R1 | 3.3V TX をユニットが H と認識するか | 高→**解決(机上)** | 00 |
| R2 | `uart.break` (ms 粒度) で DMX BREAK が灯体に通るか | 中 | 00 |
| R3 | Grove の 100Ω + 4.7k プルアップが UART 250k で問題ないか | 高→**低(机上)** | 00 |
| R4 | M5 ユニットの DE (方向) 制御の実態 | 高→**設計上解決(机上)** | 00 |
| R5 | UART TX blocking が Core0 を何 ms 止めるか / DMA 化要否 | 高 | 00, 01 |
| R6 | 各ムービングライトの正確な DMX チャート入手 | 高 | 03 |
| R7 | sample_clock とフリーランタイマの整合実測 | 中 | 02 |
| R8 | PSRAM 上 WAV 再生のレイテンシ (QMI バス競合) | 中 | 02 |
| R9 | ライブ差し替えの安全性 (Sandbox resolve_intern 破壊性) | 高 | 06 |
| R10 | 512ch 全表示の DVI テキスト負荷 | 中 | 06 |
| R11 | DMA チャネル枯渇 / 衝突 | 低 | 01 |
| R12 | 40Hz 周期 vs データ長の衝突 | 中 | 01 |
| R13 | デイジーチェーン終端 / 反射 | 中 | 00, 03, 07 |
| R14 | 音と光の知覚同期ズレ (モータ遅延) | 低 | 03, 07 |
| R15 | strudel-rb コア移植コスト (Hap/Fraction 割当・GC。Float は非ボクシングで問題なし) | 高 | 04 |
| R16 | 光と音の同期をホストで事前実証 (スパイク) | 高 | 04 |
| R17 | 連続 signal の DMX ストリーミング cadence | 中 | 04 |
| R18 | M5 DMX ユニットの 5V 消費電流 vs Grove 給電能力 | 中→**低(机上)** | 00 |
| R19 | 灯体は信号断で自動消灯しない → エンジン側 keepalive デッドマン + 異常時ブラックアウト | 高 | 01, 06, 07 |

## 設計方針メモ

- タイミングは 3 つの独立した仕組み (マスタークロック / 音エンジン / DMX エンジン) が 1 クロックを
  共有。pwm-audio は **音エンジンの手本に限定** し、DMX は独自フレームエンジン、クロックは独立
  ハードウェアタイマとする (pwm-audio をタイミング全般のテンプレートにしない)。
- schedule-ahead で「Ruby は何を・いつを決め、発火はハードウェア」。Ruby tick は低レート (~60Hz) で
  CPU/GC を抑える。
- DMA バンク分離 (新規完了 IRQ は `DMA_IRQ_0`) と Alarm 2/3 使用が安全の鍵。
- **灯体は信号断で自動消灯しない**。DMX エンジンに keepalive デッドマン (Ruby の heartbeat 断で
  自動ゼロ送出) を内蔵し、正常終了・例外時は明示的に `DMX.blackout`、起動直後にもゼロフレームを
  送って前回の固まった状態を消す。
- M4 はタイマクロック (board_millis) + 既存発音で成立。音 DMA/WAV (M5/M6) はクリティカルパス外の
  後追い強化とし、コアの音光同期デモに最短到達する。
- Grove は I2C 用設計 (3.3V/100Ω/4.7k プルアップ)。UART 250k 適合は M0 で実機確認 (最大リスク)。
- 段階 A → B → C は前段を壊さず積み増す。デモ最低ラインは M4 で成立。
- C 層 2 gem (`picoruby-dmx` / `picoruby-pwm-audio`) は DSL を待たず M2c / M6c で単体検証する。

## References

- [Strudel](https://strudel.cc/): TidalCycles を JavaScript に移植したライブコーディング環境
- [asonas/strudel-rb](https://github.com/asonas/strudel-rb): Ruby 版 Strudel。基礎互換の基準
- [M5Stack Unit DMX](https://docs.m5stack.com/en/unit/Unit-DMX): CA-IS3092W 絶縁 RS-485 DMX ユニット
- [m5stack/M5Unit-DMX512](https://github.com/m5stack/M5Unit-DMX512): ユニットの Arduino ライブラリ (esp_dmx 依存)
