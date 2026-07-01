# research 03: フィクスチャモデル (M3)

## 目的

ムービングライト (小 8 台 + 大 2 台、デイジーチェーン) を Ruby から名前と属性で扱える
ようにする。各機種の DMX チャート (personality) を定義し、属性 (pan/tilt/dimmer/color/gobo)
を絶対 ch に解決する。`dmx(:s1).pan(0.5)` が正しい ch に届くことが本マイルストーンのゴール。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、
  [research-johakyu-01-dmx-engine.md](research-johakyu-01-dmx-engine.md)
- M2c 完了 (`DMX.set` で任意 ch を実機に届けられる)。
- 実機のムービングライト現物と各機種の取扱説明書 / DMX チャート。

## 対象マイルストーン

- M3: フィクスチャモデル。完了条件 = `dmx(:s1).pan(0.5)` が正しい絶対 ch に解決される。

## 設計詳細

### モデル (`rootfs/lib/johakyu/fixture.rb`)

`Personality` (ch map) + `Patch` (base ch 割当) + `Group` の 3 層。

```ruby
# personality: 機種ごとの DMX チャート
SMALL_MOVER = Personality.new(channels: 11, map: {
  pan: 1, pan_fine: 2, tilt: 3, tilt_fine: 4, strobe: 5,
  dimmer: 6, color: 7, gobo: 8, speed: 9
})
BIG_MOVER = Personality.new(channels: 16, map: {
  pan: 1, tilt: 3, strobe: 6, dimmer: 7, color: 9, gobo: 11
})

# patch: base ch を割り当てる
patch = Patch.new
8.times { |i| patch.add(:"s#{i+1}", SMALL_MOVER, base: 1 + i*11) }  # 1,12,23,...,78
patch.add(:b1, BIG_MOVER, base: 89)
patch.add(:b2, BIG_MOVER, base: 105)

# group: 一括指定
patch.group(:smalls, [:s1, :s2, :s3, :s4, :s5, :s6, :s7, :s8])
patch.group(:bigs,   [:b1, :b2])
patch.group(:all,    :smalls, :bigs)

DMX.active_slots = patch.max_channel   # 短縮送信 (~120ch)
```

### 属性 → 絶対 ch 解決

- `dmx(:s1).pan(0.5)` → personality.map[:pan] (=1) と base (=1) から絶対 ch = base + offset - 1。
  値 0.0-1.0 を 0-255 に量子化して `DMX.set`。
- pan/tilt の 16bit (fine) 対応はオプション (coarse/fine 2ch へ分配)。
- 色は名前 → 値テーブル (personality ごとのカラーホイール位置、例 `{red: 10, blue: 30}`)。
  gobo も同様。
- グループ `dmx(:smalls).attr(...)` はメンバ各 Fixture へ同報。`.spread` でメンバ間に位相
  オフセットを付けチェイス効果を作る。

### チャネル配置 (想定)

| 機種 | 台数 | ch/台 | base ch |
|---|---|---|---|
| 小ムービング | 8 | 11 | 1, 12, 23, ..., 78 |
| 大ムービング | 2 | 16 | 89, 105 |

最大 ch ≈ 120。`DMX.active_slots` をここに設定しリフレッシュを高速化する。実際の ch/台は
R6 の実測で確定する。

### アドレス整合 (セットアップ手順、必須)

各灯体の DMX 開始アドレス (本体メニュー or DIP スイッチ) を、`fixture.rb` の patch の base ch と
**一台ずつ一致させる**。ここがズレると別の灯体や別 ch を叩いて全部誤爆する。最も間違えやすい
工程なので手順化する:

1. patch の base ch 一覧 (上表) を確定。
2. 各灯体の物理アドレスをメニュー/DIP で base ch に設定。
3. `DMX.set` で 1 灯ずつ既知 ch を振り、点いた灯体と patch の対応が一致するか目視確認。
4. 一致表 (灯体ラベル ↔ base ch ↔ 物理位置) を残し、本番セットでも同じ並びにする。

## 調査項目

### R6: 各ムービングライトの正確な DMX チャート入手 (影響: 高)

personality が違うと pan/tilt/dimmer/color が誤爆する。小 8 台・大 2 台で別チャート。

- 検証: 各機種の取説 / DIP スイッチで動作モード (ch 数) を確認。`DMX.set` で ch を 1 つずつ
  振り、灯体の挙動を観察して map を実測同定する。確定した map を `fixture.rb` に記述。

### R13: デイジーチェーン終端 / 反射 (影響: 中)

10 台直列でケーブル品質や終端により最遠の灯体で値が化ける。

- 検証: M5 ユニットの終端 SW と最終灯体の終端 120Ω を有効化。最遠灯体で値が正しいかを確認。
  本数を段階的に増やしてテスト。

### R14: 音と光の知覚同期ズレ (モータ遅延) (影響: 低)

pan/tilt は機械応答 (モータ) で光が音に遅れて見える。

- 対策 (演出設計): dimmer/strobe (電気応答=速い) を主演出にし、pan/tilt (機械=遅い) は
  ゆっくりした signal に割り当てる。フィクスチャの応答特性を計測してメモする。

## 受け入れ条件 (DoD)

- 全 10 台の personality (ch map) が実測で確定し `fixture.rb` に記述済み。
- `dmx(:s1).pan(0.5)` / `dmx(:smalls).dimmer(1.0)` 等が、対象の灯体だけ正しい ch で動く。
- `patch.max_channel` が `DMX.active_slots` に反映され短縮送信される。
- 最遠灯体まで値が化けない (終端確認)。

## 触るファイル

- 新規: `rootfs/lib/johakyu/fixture.rb`
- 確認用: `rootfs/app/dmx_check.rb` を流用 (ch スイープで map 同定)。

## 次のハンドオフ先

- [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md) (M4 以降: DSL から
  fixture を駆動)。
- 多灯チェーンの本番運用は [research-johakyu-07-demo.md](research-johakyu-07-demo.md) (M10)。
