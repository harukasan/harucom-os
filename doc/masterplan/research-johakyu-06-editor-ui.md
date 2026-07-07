# research 06: 上下分割ライブコーディング UI (M9)

## 目的

`edit.rb` の部品を再利用した上下分割アプリ `rootfs/app/johakyu.rb` を作る。下にエディタ、
上に 512ch ユニバースのリアルタイムデバッグ表示。保存/F5 で走行中のパターンを原子的に
差し替え、編集してもショーを止めない。DMX の仕組み (ch 番号 × 値の配列) を見せるのが狙い。

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、
  [research-johakyu-05-dsl-stages.md](research-johakyu-05-dsl-stages.md)
- M3 完了 (fixture)、M4 完了 (Scheduler で音光駆動)。
- 再利用部品: `Editor::Buffer`, `RubySyntax`, `Console`/`DVI::Text`, `Sandbox`。`edit.rb` の
  編集ループ構造、`irb.rb` の Sandbox loop+suspend/resume パターン。

## 対象マイルストーン

- M9: 上下分割 UI。完了条件 = 上=ステータス/ユニバース表示・下=エディタ、コード編集 +
  ch 表示 + F5 原子差し替え。

## 設計詳細

### レイアウト (106×37、上下分割)

左右だと幅が狭いため上下に分ける。エディタが下部でフル幅 106 桁を使えるので、`edit.rb` を
ほぼそのまま再利用でき、`RubySyntax.draw_line` も幅制限なしで使える。

```
┌ 上: ステータス / ユニバース (row 0..11, 毎フレーム更新, フル幅106) ──────────┐
│ row0  [Jo-ha-kyū] CYCLE ████░░░░ beat 3/4 120BPM  TX:40Hz frame:12345 act:160│
│ row1  Fixtures: s1 P▓ T▓ D██[red]  s2 ...  s8 ...                            │
│ row2            b1 P▓▓ T▓ D███[open]   b2 ...                                │
│ row3  Universe(1..160)  001:255 002:127 003:000 ... (約48ch/行 × 数行)       │
│ ...   変化した ch を一瞬反転ハイライト                                       │
├ 区切り (row 12) ───────────────────────────────────────────────────────────┤
│ 下: エディタ (row 13..36, Editor::Buffer + RubySyntax, フル幅106)           │
│  1| tempo 120                                                                │
│  2| dmx(:smalls).dimmer(saw.segment(8))                                      │
│ ...                                                                          │
│ 最下行  F5:Eval Ctrl-S:Save Ctrl-Q:Quit                         IME mode     │
└──────────────────────────────────────────────────────────────────────────────┘
```

行配分 (上 ≈12 行 / 下=エディタ) は調整可。

### エディタ部

- `edit.rb` のロジック (Buffer/undo/draw_line/RubySyntax/prompt_input) を流用し、`EDIT_TOP`
  を上部ステータス領域の下にずらすだけ。幅はフル 106 桁のまま。
- IME (`$ime`) も `edit.rb` 同様にそのまま利用。

### ユニバース可視化 (`rootfs/lib/johakyu/universe_view.rb`)

「DMX の仕組みを見せる」ための工夫:

- 最上行: サイクル進行バー + 拍カウンタ + BPM + TX 状態 (`DMX.frame_count`, active_slots)。
  音と光の同期が目で見える。
- Fixtures 行: フィクスチャごとに pan/tilt/dimmer をミニバー (`▁▂▃▄▅▆▇█` or 反転セル)、色は
  実色をパレットで表示 (`DVI::Text.set_palette` 等で red/blue を背景セルに割当)。
- Universe グリッド: 生 ch 値を 1 行あたり約 48ch のグリッドで表示。値が変化したセルを一瞬
  反転ハイライトし「今どの ch が動いたか」を可視化 → DMX が ch 番号 × 値の配列であることが
  直感的に伝わる。
- `DVI::Text.put_string` 直叩きで毎フレーム更新 (`DVI.wait_vsync` 同期)。変化セルのみ差分
  描画 (前フレーム値キャッシュ) で負荷を抑える (R10)。

### ライブ eval (原子差し替え)

- 起動時に常駐 Sandbox を 1 つ作り DSL ランタイムを load。
- F5 / Ctrl-S で `buffer.lines.join("\n")` を `compile` → 成功なら新しい Binding 群を
  `scheduler.swap` に渡し、サイクル境界で原子的に適用。
- コンパイル/実行エラーは最下行に表示し、走行中パターンは維持 (クラッシュさせない)。track
  別 last-good fallback (research 04) と組み合わせる。
- DSL eval は「副作用なく Binding 群を返す純関数」に限定し、VM 状態を汚さない。

### 異常時ブラックアウト (R19, 必須)

灯体は信号断で自動消灯しないので、アプリ側でも消灯を保証する。

- メインループ毎に `DMX.keepalive` を呼ぶ (C 側 dead-man の heartbeat)。アプリがハングしても
  dead-man が deadman_ms 後に自動でゼロ送出する (research 01)。
- アプリの例外は `begin/rescue` で捕捉し、`DMX.blackout` してからエラー表示/復帰。正常終了
  (Ctrl-Q) 時も `DMX.blackout`。
- 復旧不能時は Ctrl-Alt-Del 相当で再起動。再起動後は `dmx_init`/`dmx_start` がゼロフレームを
  送るので固まった状態が消える。

### メインループ

```
キー処理 → DMX.keepalive → Scheduler.tick(Clock.position) → Audio.update
         → 上部ステータス差分再描画 → DVI.wait_vsync
```

`audio_demo.rb` のループ構造がテンプレート。`rootfs/lib/johakyu/` が `$LOAD_PATH`
(picoruby-require) に乗り、アプリから `require` できることを起動時に確認する。

## 調査項目

### R9: ライブ差し替えの安全性 (Sandbox resolve_intern 破壊性) (影響: 高)

Sandbox の resolve_intern は破壊的で、再 eval を繰り返すと VM 状態が壊れる / メモリリーク
する恐れ。

- 検証: `irb.rb` の「常駐 Sandbox を 1 つ作り compile→execute→wait→suspend」パターンを
  踏襲。DSL eval を純関数 (Binding 群を返すだけ) に限定。100 回連続差し替えでヒープが安定
  していることを確認。

### R10: 512ch 全表示の DVI テキスト負荷 (影響: 中)

毎フレーム多数のセルを `put_string` すると Core0 負荷が上がり `wait_vsync` を落とす恐れ。

- 検証: 変化セルのみ差分描画 (前フレーム値キャッシュ)。全描画 vs 差分で `DVI.frame_count` を
  比較し 60FPS 維持を確認。負荷が高ければ表示を 160ch / ページングに制限。

### R19: 異常時ブラックアウト (影響: 高)

- 検証: アプリで例外を起こす/ループを止めると、`rescue` の `DMX.blackout` または C 側 dead-man
  で灯体が消灯すること。正常終了でも消灯すること。再起動後にゼロフレームで固まりが消えること。

## 受け入れ条件 (DoD)

- 上=ステータス/ユニバース、下=エディタの上下分割が動く。
- コード編集 (ハイライト/オートインデント/undo/IME) が `edit.rb` 同等に使える。
- F5/Ctrl-S で走行中パターンがサイクル境界で滑らかに差し替わり、エラー時も走行継続。
- 変化 ch ハイライトと fixture バー/サイクルバーが 60FPS で更新される。
- 100 回連続差し替えでヒープ安定 (R9)、差分描画で 60FPS 維持 (R10)。
- 例外/ハング/正常終了のいずれでも灯体が消灯する (R19)。`rootfs/lib/johakyu/` を require できる。

## 触るファイル

- 新規: `rootfs/app/johakyu.rb`、`rootfs/lib/johakyu/universe_view.rb`
- 再利用: `rootfs/app/edit.rb` (ロジック流用)、`rootfs/lib/irb.rb` (Sandbox パターン)、
  `rootfs/lib/console.rb`、`mrbgems/picoruby-dvi` (DVI::Text)。

## 実装メモ (2026-07-07, 実装済み・実機確認待ち)

- `rootfs/app/johakyu.rb`: JohakyuApp クラス。edit.rb は top-level メソッド/定数を VM
  全体に定義するため、そのまま複製するとレイアウト定数が衝突する。クラス化して移植した
  (編集ロジック・undo・IME・auto indent は edit.rb と同一挙動)。
- レイアウト: rows 0-5 = UniverseView (row5 セパレータ)、row6 = エディタステータス
  (eval 結果/エラーもここ)、row7..ROWS-2 = エディタ、最下行 = コマンドバー。
- メインループはキー待ちでブロックせず、毎イテレーション session.update +
  DMX.keepalive + eval poll + view.draw + sleep_ms 5。prompt_input (終了確認等) も
  待機中に update/keepalive を回すので、プロンプト中もショーと deadman が生きる。
- ライブ eval: 常駐 Sandbox 1 つを irb の compile→execute→suspend パターンで再利用
  (wait はブロックするため poll に置換、タイムアウト 2s で stop)。スクリプトは
  `rootfs/lib/johakyu/live.rb` の Live レコーダに記録するだけの純関数。sandbox タスク
  から走行中 Session を触らないのは、プリエンプティブ切替でスケジューラ配列の変更が
  競合するため。完了後に app タスクが Live#apply し、量子化スワップで境界に乗る。
  エラー時は discard + ステータス表示で走行継続 (DoD の「エラー時も走行継続」)。
- Live の replace semantics: 前回 apply が張った track のうち今回のスクリプトに無い
  ものは remove。空バッファの eval で全停止 (Strudel の hush 相当)。SoundHandle /
  DmxTarget は transform_sound / bind_dmx だけ呼ぶので、duck typing でレコーダが
  Session の代役になる。top-level DSL: tempo / audio_latency / sound / dmx / sine /
  saw / isaw / tri / cosine / euclid / mini / stack / silence。
- UniverseView (`rootfs/lib/johakyu/universe_view.rb`): 値文字列 256 種を事前生成し
  セル毎の差分描画で定常時アロケーションなし (R10 対策)。変化 ch は 250ms 反転表示。
  fixture 行は pan/tilt/dimmer/strobe/color/gobo/prism の DMX 読み戻し。行 0 は
  16 分割サイクルバー + cyc/bpm + tick/stage/late 統計 (500ms 毎更新)。
- F5 キー: picoruby-keyboard-input に F1-F12 (HID 0x3A-0x45) を追加し
  `Keyboard::F5` を定義。ファーム再ビルドで反映 (distclean 不要)。
- R19: Ctrl-Q / Ctrl-C は確認後 ensure 経由で blackout + DMX.stop。例外も ensure を
  通る。ハングは C 側 deadman (500ms)。irb 側の Ctrl-C sandbox.stop で ensure が
  走らない場合も deadman が消灯する。
- ホストテスト: tests/live_test.rb (record/apply/replace/discard、16 assertions)。
  UI 描画と Sandbox 経路はホスト対象外 (実機確認)。
- 実機確認の残り (M9 DoD): 分割表示、edit.rb 同等の編集、F5/Ctrl-S 差し替えと
  エラー時継続、ch ハイライト 60FPS、100 回連続 eval のヒープ安定 (R9)、
  blackout 経路 (R19)。

## 次のハンドオフ先

- [research-johakyu-07-demo.md](research-johakyu-07-demo.md) (M10: 統合・演出・本番)。
