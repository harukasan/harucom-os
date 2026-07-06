# research 03: フィクスチャモデル (M3)

## 目的

ムービングライト (SHEHDS LED Spot 80W 三面プリズム、同一機種 2 台、デイジーチェーン) を
Ruby から名前と属性で扱えるようにする。DMX チャート (personality) を定義し、属性
(pan/tilt/dimmer/color/gobo) を絶対 ch に解決する。`dmx(:s1).pan(0.5)` が正しい ch に
届くことが本マイルストーンのゴール。

当初は小 8 台 + 大 2 台の 2 機種 10 台構成だったが、同一機種 2 台に変更 (2026-07-06)。
他の research ファイルの台数・group 名 (`:smalls`/`:bigs`) は読み替える。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、
  [research-johakyu-01-dmx-engine.md](research-johakyu-01-dmx-engine.md)
- M2c 完了 (`DMX.set` で任意 ch を実機に届けられる)。
- 実機 2 台とベンダーマニュアル (13ch / 10ch モードの DMX チャート入手済み)。

## 対象マイルストーン

- M3: フィクスチャモデル。完了条件 = `dmx(:s1).pan(0.5)` が正しい絶対 ch に解決される。

## 設計詳細

### モデル (`rootfs/lib/johakyu/fixture.rb`)

`Personality` (ch map) + `Patch` (base ch 割当) + `Group` の 3 層。

```ruby
# personality: ベンダーマニュアルの 13ch チャート (実装は fixture.rb)
SHEHDS_SPOT_80W_13CH = Personality.new(
  name: "SHEHDS Spot 80W 13ch", channels: 13,
  map: { pan: 1, pan_fine: 2, tilt: 3, tilt_fine: 4, speed: 5,
         dimmer: 6, strobe: 7, color: 8, gobo: 9, focus: 10,
         prism: 11, motor_auto: 12, function: 13 },
  tables: { color: {...}, gobo: {...}, prism: {...}, function: {...} },
  ranges: { strobe: [16, 251] })

# patch: base ch を割り当てる (既定リグ = Johakyu.default_patch)
patch = Patch.new
patch.add(:s1, SHEHDS_SPOT_80W_13CH, base: 1)
patch.add(:s2, SHEHDS_SPOT_80W_13CH, base: 14)
patch.group(:all, :s1, :s2)

DMX.active_slots = patch.max_channel   # 26ch に短縮送信
```

### 属性 → 絶対 ch 解決

- `dmx(:s1).pan(0.5)` → personality.map[:pan] (=1) と base (=1) から絶対 ch = base + offset - 1。
  値 0.0-1.0 を 0-255 に量子化して `DMX.set`。
- pan/tilt の 16bit (fine): map の `*_fine` キーを自動検出し、coarse/fine 2ch へ分配。
- 色は名前 → 値テーブル (personality ごとのカラーホイール位置、例 `{red: 12, blue: 28}`)。
  gobo/prism/function も同様。
- グループ `dmx(:all).attr(...)` はメンバ各 Fixture へ同報。`.spread` でメンバ間に
  オフセットを付けチェイス効果を作る。

### チャネル配置

| 機種 | 台数 | ch/台 | base ch |
|---|---|---|---|
| SHEHDS LED Spot 80W (13ch モード) | 2 | 13 | 1, 14 |

最大 ch = 26。`DMX.active_slots` をここに設定しリフレッシュを高速化する。

### アドレス整合 (セットアップ手順、必須)

各灯体の DMX 開始アドレス (本体メニュー Addr) を、`fixture.rb` の patch の base ch と
**一台ずつ一致させる**。ここがズレると別の灯体や別 ch を叩いて全部誤爆する。最も間違えやすい
工程なので手順化する:

1. patch の base ch 一覧 (上表) を確定。s1 = 001、s2 = 014。
2. 各灯体の物理アドレスをメニューで base ch に設定。動作モードは 13ch (メニュー chnd)。
3. `fixture_check.rb` の Identify モードで 1 灯ずつ点灯し、点いた灯体と patch の対応が
   一致するか目視確認。
4. 一致表 (灯体ラベル ↔ base ch ↔ 物理位置) を残し、本番セットでも同じ並びにする。

## 調査項目

### R6: 正確な DMX チャート入手 (影響: 高)

personality が違うと pan/tilt/dimmer/color が誤爆する。

- 状況: ベンダーマニュアル入手済み (13ch / 10ch 両モードの完全チャート)。map は
  `fixture.rb` に記述済みで、M0-M2c のベンチ実測 (pan=1, dimmer=6, strobe<16 常時点灯,
  color 0 白, gobo 0 オープン) と矛盾なし。
- 検証: `fixture_check.rb` の Sweep モード (raw ch を 1 つずつ駆動、マニュアルの期待挙動を
  画面表示) と Wheel モード (color/gobo/prism の名前テーブル照合) で実機と突き合わせ、
  一致を確認 (2026-07-06 完了)。

### R13: デイジーチェーン終端 / 反射 (影響: 中)

2 台直列でケーブル品質や終端により最遠の灯体で値が化ける。

- 検証: M5 ユニットの終端 SW と最終灯体の終端 120Ω を有効化。最遠灯体 (s2) で値が正しいかを
  確認する。台数が減ったのでリスクは当初想定より低い。

### R14: 音と光の知覚同期ズレ (モータ遅延) (影響: 低)

pan/tilt は機械応答 (モータ) で光が音に遅れて見える。

- 対策 (演出設計): dimmer/strobe (電気応答=速い) を主演出にし、pan/tilt (機械=遅い) は
  ゆっくりした signal に割り当てる。フィクスチャの応答特性を計測してメモする。

## 受け入れ条件 (DoD)

- 全 2 台の personality (ch map) が確定し `fixture.rb` に記述済み。
- `dmx(:s1).pan(0.5)` / `dmx(:all).dimmer(1.0)` 等が、対象の灯体だけ正しい ch で動く。
- `patch.max_channel` が `DMX.active_slots` に反映され短縮送信される。
- 最遠灯体まで値が化けない (終端確認)。

## 触るファイル

- 新規: `rootfs/lib/johakyu/fixture.rb`
- 新規: `rootfs/app/fixture_check.rb` (Sweep で map 照合、Resolve で ch 解決の readback
  検証、Identify でアドレス整合、Wheel でテーブル照合、Spread でグループ同報)。

## 実装メモ (2026-07-06, fixture 層実装完了・ホスト検証済み)

`rootfs/lib/johakyu/fixture.rb` と `rootfs/app/fixture_check.rb` を実装。fixture 層の
ロジックはホスト ruby の DMX スタブテストで 38 項目全て PASS (ch 解決、16bit 量子化、
strobe レンジ、名前テーブル、グループ同報、spread、エラー検出)。

### 設計の要点

- **値のキャッシュを持たない**。ユニバースの真実は C エンジン側のみで、fixture 層は
  ch 解決と量子化だけを行い `DMX.set` / `DMX.set_range` に直行する。読み出しは `DMX.get`。
- **数値は正規化 0.0-1.0**。Integer も `to_f` されるので `dimmer(1)` は全開 (raw 1 では
  ない)。0-255 の生値は `raw(:pan, 200)` エスケープハッチで書く。
- **16bit fine は自動**。personality map の `*_fine` キーを初期化時に検出し、coarse と
  隣接なら `DMX.set_range` で 2ch を 1 回で書く。
- **strobe はレンジ属性**。`ranges: { strobe: [16, 251] }` により正の値は 16-251 に
  マップし、0 は raw 0 (常時点灯)。ベンチ実測 (strobe<16 で常時点灯) と整合。
- **名前テーブルは帯の中央値**を採用し、機体個体差による境界ズレへの余裕を持たせた
  (例 red は 8-15 の中央 12)。
- **マニュアルの CH13 は full auto 150-249 と sound 200-249 が重複**しており曖昧。
  full_auto=180 (150-199 の非重複帯)、sound=225 を採用。reset=252。
- `Patch#add` は重複名・1-512 範囲外・既存 fixture との ch オーバーラップを raise で
  検出する (アドレス誤爆をパッチ定義時に捕まえる)。
- `spread(amount)` は静的な値オフセット (メンバ i に amount * i / (n-1) を加算、
  Fixture 側で 0-1 にクランプ)。パターン位相版の spread は M4 以降で載せる。
- group はネスト可 (`patch.group(:everything, :pair, :c)` はグループ名を平坦化)。
- 既定リグは `Johakyu.default_patch` (s1=base 1, s2=base 14, group :all)。
  `Johakyu.patch = ...` で差し替え可能。`Johakyu.dmx(:s1)` が名前解決の入口。

### 実機確認結果 (2026-07-06, 全項目合格)

`run app/fixture_check.rb` を 2 台構成 (s1=001, s2=014, 13ch モード) のベンチで実施:

- Resolve モード: 全アサーション PASS (readback 判定)。
- Sweep / Wheel モード: 13ch チャートと color/gobo/prism の名前テーブルが実機と一致 (R6 完了)。
- Identify モード: 名前どおりの灯体だけが点灯 (アドレス整合完了)。最遠灯体 (s2) の
  値化けなし (R13)。
- Spread モード: 2 台同報 + pan チェイス動作。
- 同一電源サイクル内の Q 終了 → 再実行の冪等性も確認 (research-01 の未確認残を解消)。

M3 DoD 達成。

既知の単発事象: Sweep モードの HOLD 中に n キーでハードフォルトが 1 回発生、以後再現せず
(フォルトレジスタ未取得)。Ruby 層と DMX C 層の静的解析では範囲外アクセスは見つからず、
タイミング依存の C 層問題の可能性がある。再発したらデバッガ接続のままフォルトフレームを
取得する (bkpt で halt する構成)。

## 次のハンドオフ先

- [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md) (M4 以降: DSL から
  fixture を駆動)。group 名は `:all` のみになった点に注意 (`:smalls`/`:bigs` は廃止)。
- 多灯チェーンの本番運用は [research-johakyu-07-demo.md](research-johakyu-07-demo.md) (M10)。
