# Harucom OS マスタープラン

## ゴール

残り約2週間で以下の3機能を完成させ、Harucom OS を作品として仕上げる:

1. **Ruby Shell (IRB)**: DVI テキストモード上で動作するインタラクティブ Ruby
2. **テキストエディタ**: Ruby スクリプトを編集・保存できるエディタ
3. **picorabbit**: プレゼンテーションツールを Harucom 上で動作させる

## アーキテクチャ概要

I/O 経路は完全に分離する:

- **デバッグ経路**: `printf()` -> `hal_write()` -> UART TX / `hal_getchar()` <- UART RX
- **ユーザー経路**: IRB/Editor (Ruby) -> DVI::Text VRAM -> DVI 画面 / USB::Host.keyboard_* (Ruby) <- USB キーボード

HAL は UART デバッグ I/O 専用として維持し、変更しない。

```
┌─────────────────────────────────────────────────────────┐
│  Ruby アプリケーション層                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐      │
│  │  IRB     │  │ Editor   │  │ picorabbit       │      │
│  │ (Ruby)   │  │ (Ruby)   │  │ (Ruby)           │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────────────┘      │
│       │              │              │                     │
│  ┌────┴──────────────┴──┐    ┌─────┴───────────────┐    │
│  │ Console (Ruby)       │    │ DVI::Graphics (C)   │    │
│  │ テキストモード UI    │    │ グラフィックスモード │    │
│  └──┬──────────┬────────┘    └─────────────────────┘    │
│     │          │                                         │
│     │ 出力     │ 入力                                    │
│     v          v                                         │
├─────────────────────────────────────────────────────────┤
│  C 基盤層                                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ DVI::Text    │  │ USB::Host    │  │ Sandbox      │  │
│  │ VRAM API (C) │  │ keyboard (C) │  │ eval 隔離    │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│  ┌──────────────┐  ┌──────────────┐                     │
│  │ Editor::     │  │ picoruby-    │                     │
│  │ Buffer       │  │ require      │                     │
│  │ (PicoRuby)   │  │ (PicoRuby)   │                     │
│  └──────────────┘  └──────────────┘                     │
├─────────────────────────────────────────────────────────┤
│  HAL (UART デバッグ専用、変更なし)                        │
│  hal_write() -> UART TX    hal_getchar() <- UART RX     │
└─────────────────────────────────────────────────────────┘
```

## コンポーネント一覧 (Ruby/C の実装境界)

### C で実装するもの

| コンポーネント | 概要 | 新規/既存 |
|---|---|---|
| DVI::Text 追加 API | scroll_up, clear_range, get_attr, set_attr | 既存に追加 |
| DVI::Graphics 描画追加 | draw_text (8x8), draw_line, draw_image | 既存に追加 |
| Machine ポート | signal_self_manage, check_signal | 新規 |

### Ruby で実装するもの

| コンポーネント | 概要 | 新規/既存 |
|---|---|---|
| Keyboard | USB::Host API をラップした keycode->文字変換、キーリピート、修飾キー処理 | 新規 |
| Console | DVI::Text を使ったテキスト UI 基盤 (カーソル管理、スクロール、行描画) | 新規 |
| IRB | Console + Editor::Buffer + Sandbox による REPL | 新規 |
| Editor | Console + Editor::Buffer による全画面エディタ | 新規 |
| picorabbit | スライドロジック (DVI::Graphics API で再実装) | 移植 |

### PicoRuby から再利用する部品

| 部品 | パス | 用途 |
|---|---|---|
| Editor::Buffer | `lib/picoruby/mrbgems/picoruby-editor/mrblib/buffer.rb` | テキストバッファ管理 (完全再利用、修正不要) |
| Sandbox | `lib/picoruby/mrbgems/picoruby-sandbox/` | IRB の eval 隔離実行 (Machine ポート必要) |
| picoruby-require | 既にビルド済み | ファイルベースの require/load |
| mruby-task | 既にビルド済み | 協調マルチタスク |

## マイルストーン

### Milestone 1: キーボード入力 (Days 1-3)

USB キーボードから文字入力を受け取れるようにする。全機能の入力基盤。Ruby で実装する。

**新規ファイル**: Ruby スクリプト (ファームウェア埋め込みまたは /flash 配置)

**Keyboard クラス (Ruby)**:
- `USB::Host.keyboard_keycodes` / `keyboard_modifier` をポーリング
- HID keycode -> 文字変換ルックアップテーブル (初期実装は US レイアウト、テーブル差し替えで JIS 等に対応可能)
- 前回レポートとの差分で新規キー押下を検出
- Shift: shifted テーブル使用
- Ctrl + 文字: ASCII 制御コード (Integer 1-26) として返す (Ctrl-C=3, Ctrl-D=4, Ctrl-S=19, Ctrl-Q=17)
- 特殊キー: Editor::Buffer.put が受け付けるシンボルで返す (`:UP`, `:DOWN`, `:LEFT`, `:RIGHT`, `:HOME`, `:BSPACE`, `:TAB`, `:DELETE`)
- ソフトウェアキーリピート (初期ディレイ 400ms, リピート 50ms)
- `Keyboard#read_char` -> String (通常文字) / Symbol (特殊キー) / Integer (制御コード) / nil (入力なし)

**戻り値の設計**: Editor::Buffer.put にそのまま渡せる形で統一する。
IRB/Editor のループは制御コード (Integer) を先にチェックし、残りを Buffer.put に渡す。

**HAL は変更しない**: hal_write / hal_getchar は UART デバッグ専用のまま維持。

**検証**: Ruby スクリプトで `Keyboard#read_char` を呼び出し、DVI::Text.put_string で文字が画面に表示されることを確認。

### Milestone 2: DVI テキスト API 拡張 (Days 2-4)

IRB とエディタに必要なテキスト VRAM 操作を追加する。Milestone 1 と並行作業可能。

**実装内容**:

C API 追加 (`mrbgems/picoruby-dvi/`):
- `dvi_text_scroll_up(int lines, uint8_t fill_attr)` -- VRAM memmove + 末尾行クリア
- `dvi_text_clear_range(int col, int row, int width, uint8_t attr)` -- 部分行クリア
- `dvi_text_get_attr(int col, int row)` -- セル属性読み取り
- `dvi_text_set_attr(int col, int row, uint8_t attr)` -- セル属性設定

Ruby バインディング追加:
- `DVI::Text.scroll_up(lines, attr)`
- `DVI::Text.clear_range(col, row, width, attr)`
- `DVI::Text.clear_line(row, attr)` (既存 C API の Ruby 公開)
- `DVI::Text.get_attr(col, row)`
- `DVI::Text.set_attr(col, row, attr)`

**変更ファイル**:
- `mrbgems/picoruby-dvi/include/dvi.h`
- `mrbgems/picoruby-dvi/ports/rp2350/dvi_output.c`
- `mrbgems/picoruby-dvi/src/mruby/dvi.c`

**検証**: Ruby スクリプトから scroll_up, clear_range 等を呼び出し、DVI 画面で正しく描画されることを確認。

### Milestone 3: ビルド統合 + Machine ポート (Days 4-5)

Sandbox と Editor::Buffer をビルドに追加し、Machine モジュールのポートを実装する。

**ビルド設定変更** (`build_config/harucom-os-pico2.rb`):
```ruby
conf.gem core: 'picoruby-editor'     # Editor::Buffer
conf.gem core: 'picoruby-sandbox'    # eval 隔離
conf.gem core: 'picoruby-machine'    # シグナル管理
conf.gem core: 'picoruby-env'        # Sandbox 依存
```

**Machine ポート実装**:
- `Machine.signal_self_manage` / `Machine.check_signal` / `Machine.pop_signal_self_manage`: hal.c の sigint_status と統合
- `Machine.reboot`: `watchdog_reboot()` で実装

**picoruby-io-console は追加しない**: Keyboard は USB::Host API を直接使い、Sandbox は io-console に依存しないため不要。hal.c の `io_raw_q()` / `io_echo_q()` スタブはそのまま維持。

**変更ファイル**:
- `build_config/harucom-os-pico2.rb`
- `CMakeLists.txt` (ソース・インクルードパス追加)

**検証**: `rake` がエラーなくビルド完了。

### Milestone 4-7: Console + IRB, エディタ, picorabbit, ポリッシュ (Days 5-14)

Milestone 3 までが完了すれば基盤 (キーボード入力、DVI テキスト API、ビルド統合) が揃う。
Milestone 4 以降は直列に依存しており、実装しながら詳細を詰める。以下は現時点の方針。

---

#### Milestone 4: Console + IRB (Days 5-8)

DVI テキストモード上で動作する IRB を実装する。プロジェクトのコア機能。

**Console クラス (Ruby, 新規)**:
- DVI::Text API を直接使ったテキスト UI 基盤
- カーソル位置管理 (col, row)
- 文字出力: put_char でカーソル位置に配置、カーソル前進、行末折り返し、画面末スクロール
- 行クリア、画面クリア
- カーソル描画 (属性反転トグル)
- UTF-8 文字列出力 (DVI::Text.put_string に委譲)

**IRB (Ruby, 新規)**:
- Console + Editor::Buffer + Sandbox の組み合わせ
- プロンプト表示 (`irb> `)
- キー入力ループ: Keyboard#read_char -> Editor::Buffer.put
- Enter 時: try-compile による複数行判定 (`begin; _ = (...); rescue => _; end; _`)
- 実行: Sandbox.execute -> result.inspect で結果表示
- ヒストリ: 配列に保存、上下キーで切り替え
- Ctrl-C: 実行中断

**ブートシーケンス変更** (`src/main.c`):
```ruby
# ファイルシステムマウント + USB host タスク (既存)
# ...
# IRB 起動
if VFS.exist?("/flash/main.rb")
  load "/flash/main.rb"
else
  require 'irb'  # /flash/irb.rb を load
end
```

IRB の Ruby コードは `/flash/irb.rb` として配置するか、ファームウェアに埋め込む。

**検証**: 起動後 IRB プロンプトが表示され、`1 + 1` -> `=> 2` が動作すること。

### Milestone 5: テキストエディタ (Days 8-11)

IRB から呼び出せるテキストエディタを実装する。

**Editor (Ruby, 新規)**:
- Console + Editor::Buffer による全画面エディタ
- Editor::Buffer のダーティフラグで効率的な差分描画
- 基本操作: カーソル移動 (矢印、Home、End)、文字入力、バックスペース、デリート
- 行操作: 行挿入 (Enter)、行削除
- ファイル操作: 保存 (Ctrl-S)、終了 (Ctrl-Q)
- ステータスバー: ファイル名、行番号、変更フラグ

**IRB からの起動**:
```ruby
irb> require 'editor'
irb> Editor.new.open("/flash/hello.rb")
```

**画面構成**:
```
行 0:     ステータスバー (ファイル名、行番号)
行 1-35:  テキスト編集領域 (35行)
行 36:    コマンドバー (Ctrl-S:Save Ctrl-Q:Quit)
```

**検証**: エディタでファイルを開き、編集、保存、終了してIRBに戻れること。

### Milestone 6: picorabbit 移植 (Days 11-13)

プレゼンテーションツールを Harucom 上で動作させる。

**DVI::Graphics 描画追加 (C)**:
- `DVI::Graphics.draw_text(x, y, text, color)` -- 8x8 フォント (font8x8_basic)
- `DVI::Graphics.draw_line(x0, y0, x1, y1, color)` -- Bresenham
- `DVI::Graphics.draw_image(data, x, y, w, h)` -- 画像ブリット
- `DVI::Graphics.draw_image_masked(data, mask, x, y, w, h)` -- 透過画像

**画像アセット**: picorabbit の `scripts/convert_image.rb` で変換、C ヘッダーとしてファームウェアに埋め込み

**スライドロジック (Ruby)**: picorabbit の main_task.rb を 320x240 座標系に移植

**入力**: GPIO ボタンを USB キーボードに変更 (l=次, h=前, q=終了)

**モード切り替え**: IRB -> `DVI.set_mode(DVI::GRAPHICS_MODE)` -> picorabbit -> `DVI.set_mode(DVI::TEXT_MODE)` -> IRB

**検証**: IRB から picorabbit を起動し、スライド表示・切り替え・IRB 復帰が動作すること。

### Milestone 7: ポリッシュ (Days 13-14)

- ブート画面 (Harucom OS バナー)
- DVI 診断出力を UART のみに制限
- キーリピートのチューニング
- 安定性テスト (長時間動作、メモリリーク確認)
- flash 書き込み中の DVI ブランキング確認 (エディタ保存時)

## 依存関係

```
Milestone 1 (Keyboard) ──┐
                          ├──> Milestone 3 (Build) ──> Milestone 4 (IRB)
Milestone 2 (DVI API) ───┘                              │
                                                         v
                                                   Milestone 5 (Editor)
                                                         │
                                                         v
                                                   Milestone 6 (picorabbit)
                                                         │
                                                         v
                                                   Milestone 7 (Polish)
```

## リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| Machine ポートの複雑さ | 中: Sandbox が動かない | 最小実装から開始 (signal_self_manage のみ) |
| picorabbit 解像度差 (640 vs 320) | 中: 表示品質 | 320x240 で再設計 (最も現実的) |
| Editor::Buffer のビルド統合 | 低: 依存 gem の連鎖 | 最小限の gem セットで開始 |
| SRAM 不足 (mrbgem 追加後) | 低: 現在 334KB 余裕 | サイズ監視、不要機能は除外 |

## 設計方針メモ

### Editor::Buffer を共通基盤とする設計

Editor::Buffer は I/O に依存しない純粋なデータモデル。
Harucom OS の IRB/Editor は Editor::Buffer の上に独自の I/O 層 (Console + Keyboard) を構築する。

```
Harucom:  Console (DVI::Text) + Keyboard (USB::Host) -> Editor::Buffer
R2P2:    Editor::Line/Screen (ANSI + STDIN)          -> Editor::Buffer
```

この構造により、picoruby-vim のモード管理ロジック等を将来 Harucom に持ってくる際も、
Editor::Buffer への操作部分は再利用し、I/O 層だけ差し替えればよい。

### HAL の I/O 分離

HAL (hal_write / hal_getchar) は UART デバッグ専用として維持し、変更しない。
ユーザー向け I/O (画面表示、キーボード入力) は Ruby レイヤーで DVI::Text と USB::Host を直接使う。
