# research 02: オーディオエンジン拡張 (WAV + DMA + sample_clock) (M5, M6, M6c)

## 目的

既存 `picoruby-pwm-audio` に (a) サンプリング WAV のワンショット再生 と (b) DMA ペーシング
による出力を追加し、(c) 音オンセットのサンプル精度予約・遅延補正に使う `sample_clock` を
公開する。タイミングが重要なため出力を DMA 化して ISR ジッタを下げ、サンプルカウンタを
Ruby に渡す。

注: `sample_clock` は **シーケンサのマスタークロックではない**。マスタークロックは独立した
フリーランタイマ (`Machine.board_millis`, ms、research-04 参照)。`sample_clock` は schedule-ahead
で「目標時刻 → サンプルオフセット」に変換し、音バッファ遅延を補正してサンプル精度で発音する
ために使う。これにより光 (DMX) と音を同じ目標時刻に揃える。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)
- 既存実装の理解: ISR (TIMER1_IRQ_1, 優先度0) 駆動、22050Hz、DMA 未使用、リングバッファは
  `(L<<16)|R` packed uint32、`pwm_audio_calc_sample()` で 3ch ミキシング、
  `pwm_audio_fill_buffer()` は main loop から `PWMAudio.update()` でポーリング充填。
- 出力 GPIO24/25 = PWM slice 4 (ch A/B)、wrap=499、キャリア 250kHz。

## 対象マイルストーン

- M5: オーディオ WAV + DMA 化。完了条件 = WAV ワンショット再生 + ジッタ低減 +
  `audio_demo.rb` 回帰 OK。
- M6: サンプルクロック公開。完了条件 = `PWMAudio.sample_clock` (単調増加) を Ruby が読める。
- M6c: 機能確認 (単体)。完了条件 = 拡張 `audio_demo.rb` でチェックリスト全項目を確認。

## 設計詳細

注: (b)(c) は当初案。実装は異なる形で完了しており、現状の正は
[doc/pwm-audio.md](../pwm-audio.md) と本ファイル末尾の「実装結果」。(a) のサンプル再生は
未実装で、QOA 圧縮を含めて別途計画する。

### (a) WAV ワンショット PCM ch

- LittleFS 上の `.wav` を Ruby で読み `String` (PSRAM ヒープ) として保持。WAV ヘッダ解析は
  Ruby (`rootfs/lib/johakyu/wav.rb`) で行う。8/16bit PCM・モノラル前提 (デモ用途)。
- C 側に PCM 再生スロット (例 2 スロット) を追加。`pwm_audio_calc_sample` のミックスループに
  「位相アキュムレータで PCM を 22050Hz にレート変換 → vol → pan → mix」を追加。既存の
  `phase`/`phase_increment` 機構を PCM インデックスに転用 (`phase_increment = (src_rate<<16)/22050`,
  `pcm[phase>>16]`、終端で停止)。
- ワンショット: `play_pcm` で発火、末尾到達で自動停止。キック/スネア/ハットに最適。
- **WAV バイナリの同梱**: サンプルは `rootfs/data/johakyu/*.wav` 等に置き、rootfs の LittleFS
  イメージへ確実にパックされること (.rb だけでなくバイナリも含まれる) をビルドで確認する。
  flash は 16MB あるので短いドラムサンプルの容量は問題にならない。

### (b) DMA ペーシング化 (ISR ジッタ低減)

- 現状: `TIMER1_IRQ_1` が 22050Hz で 1 サンプルずつ `pwm_set_both_levels`。割り込み
  オーバーヘッドとジッタがある。
- 移行: PWM slice4 CC レジスタ (`pwm_hw->slice[4].cc`) へ DMA ch2 が直接書き込む。リング
  バッファは既に `(L<<16)|R` packed uint32 で CC レジスタと同形式なので、A/B 割り当てに
  合わせて語内位置を調整するだけ。
- ペーシング: PWM wrap (250kHz) は速すぎるため、DMA pacing timer (`DREQ_DMA_TIMER0`) を
  22050Hz に設定 (`dma_timer_set_fraction` で sysclk から分周)。
- ダブルバッファ (各 256〜512 サンプル) にし、DMA を 2ch チェーン (データ ch2 + リスタート
  control ch) もしくは 1ch + `DMA_IRQ_0` 完了割り込みで半面を `pwm_audio_fill_buffer` 再充填。
- 移行方針: `pwm_audio_port.c` だけ差し替え、`src/pwm_audio.c` (合成・ミックス) は不変。
  `PWMAudio.update` (ポーリング充填) API も維持し内部実装だけ DMA 化 (後方互換)。

### (c) sample_clock 公開

- `pwm_audio_sample_clock()` は累計転送済みサンプル語数 (uint64) を返す。DMA 完了 IRQ
  (`DMA_IRQ_0`) で半バッファ分を加算する、もしくは DMA の転送カウンタから算出する。
  この IRQ は元々バッファ充填で発生するので、加算は実質追加 CPU ゼロ。
- Ruby: `PWMAudio.sample_clock` → 64bit 相当の単調増加値。**マスタークロックではなく**、
  schedule-ahead で音オンセットを目標時刻 (µs) からサンプルオフセットへ変換するために使う
  ([research-johakyu-04-pattern-core.md](research-johakyu-04-pattern-core.md))。

### DMA 資源

- ch2 = オーディオ、pacing timer 0 を使用。完了 IRQ は `DMA_IRQ_0` (DVI の `DMA_IRQ_1` と
  バンク分離)。`dma_claim_unused_channel` で取得。

## 調査項目

### R7: sample_clock とフリーランタイマの整合実測 (影響: 中)

クロック方針は決定済み (マスター = フリーランタイマ、`sample_clock` = 音オンセット予約用)。
残る検証は両者の整合と精度。

- 検証: M5/M6 後、`Audio.sample_clock` と `time_us_64` を一定間隔で記録し、両者の換算
  (sample ≈ µs × 22050 / 1e6) がドリフトしないか測定。schedule-ahead の lookahead を
  「音バッファ遅延 + 1 DMX フレーム」以上に設定したとき、音オンセットがサンプル精度で目標
  時刻に乗るかを確認。

### R8: PSRAM 上 WAV 再生のレイテンシ (QMI バス競合) (影響: 中)

PCM を PSRAM (0x11000000, cached) から ISR/DMA ミックス時に読む。flash と共有 QMI のバス
競合でアンダーランの恐れ。

- 検証: 代表 WAV を PSRAM に置き `play_pcm`、FIFO empty 検出 (既存 `pwm_audio_rd == wr`) と
  ノイズを確認。NG なら小サンプルを SRAM へコピー、または flash 直読。

## M6c 機能確認チェックリスト (拡張 `rootfs/app/audio_demo.rb`)

DSL に依存せず公開 API を直接叩く。既存 `audio_demo.rb` を拡張し、恒久スモークテストにする。

- `tone(ch, freq, waveform:, volume:)` を 4 波形 (SINE/SQUARE/TRIANGLE/SAWTOOTH) × 3ch で
  発音、`pan` / `mute` / `stop` / `stop_all` が効く。
- `beep` (ブロッキング) が鳴る。
- 新規 `play_pcm(slot, wav, rate, vol)`: LittleFS 上の WAV をワンショット再生し終端で自動
  停止、シンセ ch とミックスされる (キック/スネア等)。
- 新規 `sample_clock`: 単調増加で、一定間隔の読み取りからレート ≈ 22050/s、後退ジャンプ無し。
- DMA 経路でアンダーラン無し (`pwm_audio_rd == wr` 監視)、クリック/ジッタが ISR 版より
  悪化しない。
- 既存 `audio_demo.rb` の従来機能が回帰 (M5 で壊していない)。

## 受け入れ条件 (DoD)

- M5: WAV ワンショットが鳴り、出力が DMA 駆動になり、既存機能が回帰なし。
- M6: `PWMAudio.sample_clock` が単調増加で ≈22050/s。
- M6c: 上記チェックリスト全項目を確認済み。拡張 `audio_demo.rb` が常駐。

## 触るファイル

- 変更: `mrbgems/picoruby-pwm-audio/include/pwm_audio.h`、`src/pwm_audio.c`、
  `ports/rp2350/pwm_audio_port.c`、`src/mruby/pwm_audio.c`
- 変更/拡張: `rootfs/lib/board/pwm_audio.rb`、`rootfs/app/audio_demo.rb`
- 新規: `rootfs/lib/johakyu/wav.rb`
- 新規 `MRB_SYM()` 追加時は `rake distclean` が必要。

## 実装結果 (2026-07-08、M5/M6 実機確認済み)

計画と異なる点を含む最終形:

- **fs = 50000Hz、搬送波 250kHz** (wrap=999、1 サンプル = ちょうど 5 搬送波周期、分解能
  1000 レベル)。22050Hz は放棄した: clk_sys 250MHz (dvi_clock.c がオーバークロック) =
  2^7·5^9 は因数 3 を持たず 22.05k/24k/48k 系は整数分周できない
- **ペーシングは DMA タイマではなく、ピンレスなペーサスライス (slice 8) の wrap DREQ**
  (wrap+1=5000、1 wrap = 1 サンプル = 1 CC 書込)。DMA の DREQ には分周が無いため音声
  スライス自身では 1/5 レートを作れない。両スライスのカウンタをプリセットして同時
  イネーブルすることで、CC 書込が常に搬送波周期の中央に着地する (位相自由度ゼロ)
- 根本原因の記録: 従来の高音「パチパチ」は **fs と搬送波の非整数比ビート** だった。CC は
  wrap 時のみラッチされるため、非整数比ではサンプル境界が搬送波グリッド上で揺れ、ビートが
  信号スロープ比例のクラックになる (旧 ISR 版も 500kHz/22050=22.68 周期で該当)。整数比化で
  消滅を実機確認 (pacing drift が定数のまま伸びない)
- 転送は単一 DMA チャネル + read リング (8KB align) + RP2350 ENDLESS モード (継ぎ目なし)。
  deinit は RP2350-E5 対応 (abort 前に EN クリア)
- レンダは TIMER1 alarm 1 の 10ms ポンプで **C が自律充填** (Ruby の update は互換 no-op)。
  VM が止まってもアンダーランしない
- `PWMAudio.sample_clock` / `tone_at` / `stop_at` / `cancel_scheduled` / `SAMPLE_RATE` を追加
  (イベントキュー 32 件、レンダ中にサンプル精度で適用)。診断 `PWMAudio.stats` =
  [min_lead, max_gap_us, drift_now, drift_min]
- audio_demo.rb は不変 (デモに検証機能は足さない方針)。検証は irb から `PWMAudio.stats` /
  `sample_clock` / `tone_at` を直接叩く
- この改修は main の PR 14 (pwm-audio-wrap-dreq) としてマージ済み。API と構造の正式な
  ドキュメントは [doc/pwm-audio.md](../pwm-audio.md)
- 未実施: サンプル再生 (計画 (a)、QOA 圧縮対応を含めて別途計画) と R8。M10 のゲートには
  しない

## 次のハンドオフ先

- [research-johakyu-04-pattern-core.md](research-johakyu-04-pattern-core.md) (M4 土台:
  `sample_clock` を schedule-ahead の音オンセット予約に使う。マスタークロックは別途タイマ)。
- DMA バンク整合は [research-johakyu-01-dmx-engine.md](research-johakyu-01-dmx-engine.md) と
  合わせて確認 (両者とも `DMA_IRQ_0`)。
