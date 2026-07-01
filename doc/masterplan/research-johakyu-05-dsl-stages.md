# research 05: 段階的 DSL と DMX 統合 (M4, M7, M8)

## 目的

research 04 のパターンコアの上に、ユーザーが書く DSL を段階的に積む。段階A (ステップ
シーケンサ) でデモ最低ライン (音光同期) を成立させ、段階B (ミニ記法)、段階C (パターン演算
+ signal) と前段を壊さず拡張する。音と DMX が 1 つの DSL で同期するのが核。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、
  [research-johakyu-04-pattern-core.md](research-johakyu-04-pattern-core.md)
- M3 完了 (fixture モデルで属性 → ch 解決)、パターンコア動作 (research 04)。
- **M4 は音 DMA/WAV (M5/M6/M6c) に依存しない**。マスタークロックは `board_millis`、発音は既存
  `tone`/`beep` で足りる。サンプル精度の音オンセット (sample_clock) は M8 以降で後追い。

## 対象マイルストーン

- M4: Clock + Scheduler + 段階A。完了条件 = タイマクロック基準でステップが音 + 光を駆動
  (キックの瞬間に dimmer が立つ。音は既存 `tone`/`beep` で可)。
- M7: ミニ記法 (段階B)。完了条件 = `sound("bd ~ sn ~")` / `color("red blue")` 動作。
- M8: パターン演算 + signal (段階C)。完了条件 = fast/slow/every/rev/euclid + `sine.slow` が
  パン/ディマーに効く。

## 設計詳細

### DSL バインド (`rootfs/lib/johakyu/dsl.rb`)

Pattern と出力ターゲットを分離し、`sound`/`dmx` でバインドする。同じ変換が両方に効く。

```ruby
# 音ターゲット (strudel-rb 互換)
sound("bd ~ sn ~")
note("c e g").s(:saw)

# DMX ターゲット (Johakyu 独自、fixture 属性へ)
dmx(:smalls).dimmer(saw.segment(8))      # 連続 → ディマー
dmx(:smalls).color("red ~ blue ~")       # 離散 → 色
dmx(:bigs).pan(sine.slow(4)).tilt(tri.slow(3))  # signal → パン/チルト
dmx(:all).strobe(euclid(5, 8))

# 変換は音/DMX 共通
dmx(:smalls).dimmer(saw.segment(8).fast(2).every(4) { |p| p.rev })
```

内部的には `dmx(:group).attr(pattern)` が Binding (対象 group/fixture, 属性名, pattern) を
返し Scheduler に登録。tick 時に Pattern を query し、value を fixture の ch map 経由で
`DMX.set` に解決。音 Binding は value を `Audio.note/play` に解決。

### 段階A (ステップシーケンサ) — M4

最初に確実に動かす土台。配列ベース。

```ruby
tempo 120
seq(:bd, [1,0,0,0, 1,0,0,0])                  # 8 ステップのキック
dmx_seq(:smalls, :dimmer, [255,0,128,0, 255,0,128,0])
dmx_seq(:smalls, :color,  [:red, :red, :blue, :blue])
```

M4 のデモ最低ライン = 「キックの瞬間に dimmer が立つ」を 1 チャンネルで確認 (音光同期の
最小実証)。内部は段階B/C と同じ Pattern に変換して Scheduler に乗せる (配列 → `fastcat`)。

### 段階B (ミニ記法) — M7

`rootfs/lib/johakyu/mini.rb` に strudel-rb 互換の手書きパーサを実装。サポート範囲:

| 記法 | 意味 |
|---|---|
| `bd hh sd` | 列 (sequence) |
| `bd*2` | 高速化 (n 倍) |
| `bd!3` | 複製 (n 回) |
| `bd/2` | 低速化 (1/n) |
| `[bd hh]` | グループ |
| `<a b c>` | サイクル毎に 1 要素選択 |
| `bd, hh*4` | 並列スタック |
| `bd:2` | サンプル番号 |
| `~` / `-` | 休符 |
| `_` | ホールド (前の値保持) |

```ruby
sound("bd ~ sn ~")
sound("bd*2 [sn cp]")
dmx(:smalls).color("red blue red blue")
```

### 段階C (パターン演算 + signal) — M8

research 04 のコアの変換と signal をフルに使う。連続 signal がムービングライトのパン/チルト/
フェードにそのまま対応する点が肝。

```ruby
sound("bd*4").every(4) { |p| p.fast(2) }
dmx(:smalls).dimmer(saw.segment(16).slow(2))
dmx(:bigs).pan(sine.range(0.2, 0.8).slow(8))
dmx(:all).strobe(euclid(3, 8))
```

任意拡張: jo/ha/kyu アレンジ区分 (`jo { } / ha { } / kyu { }` で各区分のテンポ・強度・
ライト密度を宣言し、Scheduler が区分間を遷移して山場を構築)。

## 調査項目

### R15 / R17 の負荷再評価 (影響: 中)

research 04 で計測した 1 tick query コストを、実際の DSL (複数バインド・連続 signal 多数) で
再評価する。

- 検証: 想定デモパターン (音数本 + DMX 連続数本) を流し、Scheduler.tick の所要時間と GC、
  DVI 60FPS 維持、DMX/Audio アンダーランの有無を計測。重い場合は連続 cadence を下げる、
  バインド数を制限する、`Fraction` を固定小数点化する等で調整。

## 受け入れ条件 (DoD)

- M4: 段階A の配列 DSL で、タイマクロック基準にステップが音 + 光を駆動。「キックで dimmer が
  立つ」を実機確認。
- M7: ミニ記法サブセット (上表) が動作。`sound("bd ~ sn ~")` と `color("red blue")` が期待
  どおり。
- M8: fast/slow/every/rev/euclid と signal (`sine.slow` 等) がパン/ディマーに効く。
- 想定デモ規模で Scheduler が 60FPS とアンダーラン無しを維持。

## 触るファイル

- 新規: `rootfs/lib/johakyu/{dsl.rb,mini.rb}`
- 既存 (research 04): `pattern.rb`/`signal.rb`/`clock.rb`/`scheduler.rb` を利用。
- 依存: `fixture.rb` (research 03)、`DMX`/`Audio` (research 01/02)。

## 次のハンドオフ先

- [research-johakyu-06-editor-ui.md](research-johakyu-06-editor-ui.md) (M9: この DSL を
  ライブコーディングする UI)。
