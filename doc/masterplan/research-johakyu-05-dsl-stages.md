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

## 実装メモ (2026-07-07 更新, 段階A/B 実機確認済み・段階C 実装済み)

段階A (M4)・段階B (M7) は実機確認済み (M7 はプリセット 4 で sound/dimmer/color を確認)。
段階B の実装記録:

- `rootfs/lib/johakyu/mini.rb`: 手書き再帰下降パーサ + strudel-rb 移植の「サイクル番号 →
  イベント列」インタープリタ。表のサブセット全対応 (列 / `*n` / `!n` / `/n` / `[...]` /
  `<...>` / `,` スタック / `:n` / `~` `-` / `_` ホールド)。ホストで strudel-rb の
  Mini::Parser と Hap 列差分 29 ケース全一致。コンビネータ合成でなくインタープリタ移植
  なのは `_` と `!` の意味論保持と割り当て削減のため。
- `Pattern.reify` をフックし、パターンを受ける所ならどこでも String がミニ記法になる
  (struct/mask/演算の右辺も含む)。
- `Session#sound("bd ~ sn ~, hh*8")`: 値 (ボイス名 or `{s:, n:}`) を VOICES で発音。
  `:n` は WAV (M5) まで無視。track 名 `:sound`、latency 補正対象。
- `Session#dmx(:s1).dimmer("1 0 0.5 0").color("<red blue>")`: チェーン可能な per-target
  バインダ。track 名は dmx_seq と同一なので配列スタイルとミニ記法スタイルは同じ track を
  境界量子化で置き換え合える。ミニ記法の数値文字列は正規化 Float、それ以外は名前テーブル。
- 確認用: `johakyu_demo` プリセット 4 がミニ記法駆動 (sound + 両灯体の dimmer/color)。

段階C (M8) を実装、実機確認待ち:

- `Session#sound(...)` が SoundHandle を返し、fast/slow/rev/every/euclid/struct/mask/
  degrade_by が呼び出し後にチェーンできる (`sound("bd*4").every(4) { |p| p.fast(2) }`)。
  バインドは次の update まで遅延し、チェーン全体の最終パターンで一度だけ track を置き換える
  (リンクごとに即バインドすると初回サイクルに未変換パターンが乗るため)。
- `Pattern#continuous?` プローブ (微小 span を query して whole 無しなら連続) を追加し、
  `bind_dmx` が離散 (staged) と連続 (毎 tick サンプル) を自動振り分け。
  `dmx(:s2).pan(Johakyu.sine.range(0.3, 0.7).slow(8))` がそのまま効く。dmx_signal は
  同じ経路への別名として残置。連続→離散の再バインドは境界量子化スワップ
  (scheduler が staged_until を swap 境界に合わせる)。
- `write_dmx` が Boolean を扱う (euclid の true → 1.0)。`Pattern.active_value?` で
  bool パターンの truthiness を統一し、ミニ記法の "0" (String) を偽扱いに
  (struct/mask で "1 0" が期待どおり動く)。
- ショートハンド: `Johakyu.euclid(3, 8)` と `Johakyu.mini("1 0")` (reify 位置以外で
  変換チェーンする用)。
- 確認用: `johakyu_demo` プリセット 5 (sound スタック + every/fast + euclid スネア、
  s1 = saw.segment(8).slow(2) の dimmer、s2 = 連続 sine の dimmer + pan スイープ)。
  プリセット 1-4 は s2 の pan を 0.5 にバインドして track 集合を揃える。
- R15 再評価: プリセット 5 の実機初回測定は tick 平均 20.5 ms / 最大 321 ms /
  late 最大 569 ms (deadman 500 ms 超え) で不合格。原因は (1) 連続シグナルの毎 tick
  サンプリングが query 経路でコンビネータ層ごとに Fraction/TimeSpan/Hap を割り当て、
  実機 (boxed Float + PSRAM ヒープ) の GC 圧を支配、(2) sound スタック (every + stack +
  euclid) の 1 サイクル staging が単発スパイクになり pump を塞ぐ。対策 3 点:
  - Signal クラス: fast/slow/range を 3 つの Float 係数
    (time_scale/value_scale/value_offset) に畳み込み、sample() はブロック呼び出し 1 回 +
    Float 演算 3 個。Fraction/Hap を作らない。scheduler は Pattern#sample 経由で
    サンプル (汎用 Pattern は従来の query フォールバック)。
  - 連続サンプリングを CONTINUOUS_INTERVAL_MS = 25 ms (DMX 40 Hz フレーム) に制限。
  - STAGE_CHUNK を 1/2 サイクルにしてスパイクを半減、ミニ記法にサイクル単位の
    1 エントリ memo を入れて再クエリ増を相殺。
  ホスト (test VM) では update 平均 59 → 11 us / 最大 1524 → 649 us、発火イベント数は
  不変。実機の再測定はプリセット 5 の画面表示 (tick avg/max, late max) で行う。
- mruby 注意: この mruby は super にブロックを転送しない (リテラルブロックも
  `super(&proc)` も親に届かず @query が nil になった)。Signal は Pattern の @query を
  直接代入して回避。
- ホストテスト: `rake test` に M8 分を追加 (continuous? プローブ、SoundHandle チェーン、
  euclid の DMX 構造化、連続→離散スワップ、String "0" の truthiness)。

段階A の記録 (M4 時点):

- `session.tempo(bpm)` / `session.seq(:bd, [1,0,0,0])` /
  `session.dmx_seq(:s1, :dimmer, [1.0, 0, 0.5, 0])` /
  `session.dmx_signal(:all, :pan, Johakyu.sine.slow(4))` (連続バインド)。
- 配列は `fastcat` の Pattern に変換して Scheduler に乗せるので、段階B/C は同じ track に
  ミニ記法/変換済み Pattern を渡すだけで積み増せる。
- 休符規約: seq は 0/nil が休符。dmx_seq は nil のみ休符で 0 は実値 (dimmer 0 =
  そのステップで消灯)。Integer は raw 0-255、Float は正規化 0.0-1.0、Symbol は名前テーブル。
- 音は `Board::PWMAudio` の tone をボイス表 (bd/sn/hh: ch/周波数/波形/ゲート ms) で代用し、
  ゲート終了は Session が pending で管理 (WAV 化は M5/M6)。
- 同名 track の再バインドは次サイクル境界で量子化スワップ (research 04)。
- リグ変更 (同一機種 2 台) により本ファイルの例の `:smalls`/`:bigs` は `:all`/`:s1`/`:s2`
  に読み替える (research 03)。

M4 の実機確認手順は research 04 の「ベンチ確認の残項目」を参照
(`run app/johakyu_demo.rb`、プリセット 1 が DoD の「キックで dimmer が立つ」)。

## 次のハンドオフ先

- [research-johakyu-06-editor-ui.md](research-johakyu-06-editor-ui.md) (M9: この DSL を
  ライブコーディングする UI)。
