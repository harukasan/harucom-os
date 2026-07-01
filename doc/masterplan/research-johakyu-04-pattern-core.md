# research 04: strudel-rb 互換パターンコア + 光音同期 (M4 土台)

## 目的

[`asonas/strudel-rb`](https://github.com/asonas/strudel-rb) の基礎部分と互換な Pattern
コアを mruby に移植し、音と DMX を同一クロックで同期駆動できることを確かめる。本ファイルは
DSL (research 05) と UI (research 06) の土台。最大の不確実性は (1) 同期モデルが本当に成立
するか、(2) mruby/RP2350 で移植コストが許容内か、の 2 点で、(1) はハードウェア不要の
ホストスパイクで先に潰す。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)
- 並行で読むと良い: [research-johakyu-02-audio-engine.md](research-johakyu-02-audio-engine.md)
  (`sample_clock` は音オンセット予約に使う。マスタークロックは独立タイマ)。
- strudel-rb のソース参照: `lib/strudel/core/{pattern,hap,time_span,fraction}.rb`、
  `lib/strudel/scheduler/cyclist.rb`、`lib/strudel/mini/parser.rb`、`lib/strudel/dsl.rb`。

## 対象マイルストーン

- M4 の土台 (Clock + Scheduler のコア)。M4 自体の段階A 統合は
  [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md)。

## 設計詳細

### 互換に取るコア (strudel-rb の確認済み事実)

- `Pattern#query(state)` / `query_arc(begin, end)`: 時間アーク → `Hap` 列。
- `Hap(whole, part, value)`、`has_onset?` (= `whole.begin == part.begin`)。
- `TimeSpan`、`Fraction` (有理数時間)。
- ファクトリ: `pure`, `silence`, `fastcat`/`sequence`, `slowcat`, `stack`, `euclid`
  (bjorklund)。
- 変換: `fast`, `slow`, `rev`, `every`, `struct`, `mask`, `degrade_by`, 算術
  (`add/mul/pow`)。
- 連続 signal の離散化: `segment(n)` (連続を 1 サイクル n 個へサンプリング)、
  `range(min, max)` (0.0-1.0 → min..max)。signal (saw/sine/tri) は連続パターン。
- トップレベル名: `sound`/`s`, `note`/`n`, `stack`, `cat`, `setcps`/`setcpm`/`setbpm`。

### クロック (`rootfs/lib/johakyu/clock.rb`) — 差し替え可能、既定=フリーランタイマ

マスタークロックは **独立したフリーランタイマ**。Ruby は **既存の `Machine.board_millis` (ms)**
を読むだけでよい (新規 C binding 不要、distclean も不要)。60Hz tick・40Hz DMX に対し ms 解像度で
十分 (位置誤差 ≤1ms は tick 間隔 16ms に対し無視できる)。常時稼働で保守 CPU はゼロ、音エンジンに
依存しない (音が止まっても DMX 演出は継続)。`Clock` は小さな抽象にして差し替え可能にする
(既定 = `TimerClock(board_millis)`、将来サブ ms が要れば `time_us_64` の µs バインドや
`AudioSampleClock` に交換可)。

```ruby
class Clock                                    # 既定: board_millis 実装
  def initialize(bpm: 120, bpc: 4)             # bpc: beats per cycle
    @ms_per_cycle = 60_000.0 / bpm * bpc
    @origin = Machine.board_millis              # 既存 API (ms)
  end
  def position                                  # 単調増加のサイクル位置 (Float)
    (Machine.board_millis - @origin) / @ms_per_cycle
  end
end
```

`setcps`/`setcpm`/`setbpm` を strudel-rb 互換に提供 (cps → `@ms_per_cycle` 換算)。サブ ms 精度が
要る音オンセットは `sample_clock` 側で担保するので、マスタークロックは ms で割り切る。

参考: strudel-rb の `Cyclist#generate` は `frame_count * cps / sample_rate` で音サンプルから
サイクルを進める (音=クロック)。Johakyu は音合成を C が担い Ruby はクロックを読むだけなので、
クロックを音から切り離し独立タイマを基準にできる。

### Scheduler (`rootfs/lib/johakyu/scheduler.rb`) — schedule-ahead + 2 系統ディスパッチ

低レート (例 60Hz = DVI フレーム毎) で tick し、`[last, now + lookahead)` を先読み query する。
各離散オンセットの **正確な発火時刻** (サイクル位置 → µs) を計算し、音はサンプルオフセットに
変換して C エンジンへ予約、DMX は目標フレーム前にユニバースへ書く。発火そのものはハードウェアが
時刻どおりに行うので、Ruby の tick を上げなくても精度が出る。

```ruby
LOOKAHEAD = ...   # サイクル単位。>= (音バッファ遅延 + 1 DMX フレーム)

def tick
  now = @clock.position
  horizon = now + LOOKAHEAD
  @bindings.each do |b|
    b.pattern.query_arc(@last_q, horizon).each do |hap|
      next unless hap.has_onset?              # 離散イベント
      at_us = @clock.cycle_to_us(hap.whole.begin)  # 発火目標時刻
      b.fire(hap.value, at_us)               # 音: Audio.schedule(sample, ...) / DMX: 目標フレームへ
    end
    b.sample_continuous(now) if b.continuous? # 連続: 現在値を毎 tick 書込み
  end
  @last_q = horizon
end
```

- 離散 Hap (`has_onset?`) はトリガ。Hap の `value` (Hash) を見て音キー (`:s`/`:note`/`:n`) →
  オーディオ (schedule-ahead でサンプル予約)、DMX キー (`{dmx:, attr:, value:}`) → ユニバース
  へ振り分ける (strudel-rb の `trigger_sound` を一般化)。
- 連続バインド (signal を DMX 属性に繋いだもの) は毎 tick `query` して現在値を `range`/
  `segment` 経由で DMX レベル ch に書く (strudel-rb の `Cyclist` には無い拡張)。連続値は
  schedule-ahead 不要 (DMX フレーム or DVI フレームの粒度で十分滑らか)。
- ライブ差し替えは整数サイクル境界で量子化 (`swap` を `@pending` に置き境界で適用)。
- track 別 last-good fallback (strudel-rb の `tracks` 同様) で、1 つのバインドが query
  エラーでも全体を黙らせない。

### 移植方針

- ボトルネックは **オブジェクト割り当て (Hap/Fraction) と GC**。Float は問題ではない (この
  ビルドは `MRB_INT64` のみで NaN/Word boxing 無し = Float は mrb_value インラインで heap 割り当て
  なし)。`Fraction` 有理数は重い恐れがあるので、サイクルを整数 tick (例 1/960 サイクル) で表す
  固定小数点や軽量有理数に置換を検討 (R15)。`Hap` も再利用/配列化で割り当てを抑える。
- なお `MRB_INT64` のため 64bit 整数演算は Cortex-M33 で数命令になる点に留意 (大きな問題ではない)。
- ミニ記法パーサ (research 05) は Parslet ではなく mruby 向け手書き。
- 音側合成は C (PWM/WAV) が担い、Ruby は query とディスパッチのみ。

## 調査項目

### R16: 光と音の同期をホストで事前実証 (スパイク) (影響: 高)

ハードウェア不要・即日できる移植前検証。

- 手順: PC 上の strudel-rb で `Scheduler::Cyclist` の dispatch を拡張し、Hap を「音」と
  「DMX シンク (ログ出力、または USB シリアル経由の実 M5 ユニット)」へ振り分ける。
- 確認: 音と DMX が同一 onset・同一サイクルで発火すること。連続 signal を `segment`/`range`
  で DMX レベルにストリームできること。
- 成果: 2 系統ディスパッチと連続サンプリングの設計を実コードで確証し、mruby 移植の不確実性を
  消す。
- 注: ホストの strudel-rb は音サンプル基準のクロックだが、これは dispatch モデルの実証が目的。
  Harucom 側のマスタークロックは独立タイマ + schedule-ahead (上記) で、クロック源の違いは
  ディスパッチの正しさに影響しない。

### R15: strudel-rb コアの mruby 移植コスト (影響: 高)

`Hap`/`Fraction` のオブジェクト割り当てと GC が mruby/RP2350 で重い恐れ (Float は前述のとおり
非ボクシングで問題なし)。

- 検証: 1 ブロック (1 tick) あたりの query 時間と GC 頻度を実機計測。`Fraction` を軽量
  有理数 or 固定小数点に置換した場合の差を比較。`Hap` 割当を抑える (オブジェクト再利用や
  配列化) 効果を測定。

### R17: 連続 signal の DMX ストリーミング cadence (影響: 中)

- 検証: `segment`/`range` のサンプリング頻度 (40-60Hz) を変え、光の滑らかさと Core0 負荷・
  DVI 60FPS 維持のバランスを計測。query は音声ブロック毎でなく専用 cadence (例 DVI フレーム)
  で回し、音 onset は小数サイクル位置を C 側サンプルオフセット遅延に変換してサンプル精度を
  確保できることを確認。

## 受け入れ条件 (DoD)

- R16: ホスト上で「音 + 光が同一サイクルで同期発火」「連続 signal が DMX に滑らかに乗る」を
  実コードで確認済み。
- R15: mruby での 1 tick query コストと GC 影響が計測され、`Fraction` の扱い (有理数 or
  固定小数点) が決定済み。
- `Clock`/`Scheduler`/`Pattern` コアが mruby 上で動き、**フリーランタイマ基準**でサイクルが
  進む。schedule-ahead で音オンセットがサンプル精度で予約され、光と音が同じ目標時刻に揃う。
- `Clock` が差し替え可能な抽象になっている (既定 = TimerClock)。

## 触るファイル

- 新規: `rootfs/lib/johakyu/{pattern.rb,signal.rb,clock.rb,scheduler.rb}`
- ホストスパイク: strudel-rb のローカルクローン (リポジトリ外) に dispatch 拡張を当てる。
- 参照: strudel-rb `lib/strudel/core/*`、`lib/strudel/scheduler/cyclist.rb`。

## 次のハンドオフ先

- [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md) (M4 段階A / M7 / M8)。
