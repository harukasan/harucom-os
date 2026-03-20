# PicoRuby 部品の再利用可能性

## 調査結果サマリー

Editor::Buffer は描画に一切依存しない純粋なデータモデルであり、そのまま再利用できる。
Sandbox は eval の隔離実行を提供するが、Machine モジュール (シグナル管理) への依存がある。
picoruby-eval は空実装 (ダミー) のため利用価値なし。

## 詳細

### Editor::Buffer

ファイル: `lib/picoruby/mrbgems/picoruby-editor/mrblib/buffer.rb`

ANSI エスケープシーケンス、IO 操作、ターミナル操作への依存が一切ない純粋なデータモデル。

主要な公開メソッド:

- **初期化・状態**: `initialize`, `clear`, `empty?`, `dump` (バッファ内容を文字列として返す)
- **カーソル移動**: `home`, `head`, `tail`, `bottom`, `up`, `down`, `left`, `right`, `move_to(x, y)`, `word_forward`, `word_backward`, `word_end`
- **行編集**: `put(c)` (文字挿入、`:ENTER`, `:TAB`, `:BSPACE` 等のシンボルも受付), `delete`, `delete_line`, `insert_line`, `replace_char`, `insert_string_after_cursor`
- **選択・クリップボード**: `start_selection(mode)`, `clear_selection`, `has_selection?`, `selection_range`, `selected_text`, `delete_selected_text`
- **UTF-8 ヘルパー** (Editor モジュールメソッド): `utf8_byte_length`, `char_bytesize_at`, `display_width`, `byte_to_display_col`, `display_col_to_byte`, `display_slice`
- **ダーティフラグ**: `mark_dirty(level)`, `clear_dirty`, `dirty` (`:none`, `:cursor`, `:content`, `:structure`)
- **アクセサ**: `lines` (行配列), `cursor_x`, `cursor_y`, `changed`

ダーティフラグは描画の最適化に有用。`:cursor` なら現在行のカーソル位置だけ更新、`:content` なら現在行を再描画、`:structure` なら全画面再描画、と判定できる。

**判定: そのまま再利用可能。修正不要。**

### Sandbox

ファイル:
- `lib/picoruby/mrbgems/picoruby-sandbox/mrblib/sandbox.rb`
- `lib/picoruby/mrbgems/picoruby-sandbox/src/mruby/sandbox.c`

タスクベースの隔離実行環境。コンパイル、実行、結果取得を提供する。

主要 API:
- `Sandbox.new(name)` -- 隔離環境を作成
- `compile(script)` -> boolean -- Ruby コードをバイトコードにコンパイル (構文エラー時 false)
- `execute` -> boolean -- コンパイル済みスクリプトを実行
- `wait(timeout:)` -> boolean -- 完了またはタイムアウトまでブロック
- `suspend` / `resume` / `terminate` -- タスク制御
- `result` -- 実行結果の値
- `error` -- 例外オブジェクト (あれば)

HAL 依存:
- `Machine.pop_signal_self_manage` -- `wait()` 内でシグナル管理
- `Machine.check_signal` -- シグナルチェック
- `Machine.read_memory(address, size)` -- RITE バイトコード検出用
- `Signal.trap(:CONT)`, `Signal.raise(:INT)` -- シグナル処理
- `Watchdog.disable` -- ウォッチドッグ制御
- `sleep_ms(ms)` -- ミリ秒スリープ (利用可能)

C 実装は `mrc_load_string_cxt()` をラップしており、タスク管理 (`mrb_create_task`, `mrb_resume_task` 等) を行う。

**判定: 再利用可能。ただし Machine モジュールのポート実装が必要。**

### picoruby-eval

ファイル: `lib/picoruby/mrbgems/picoruby-eval/mrblib/eval.rb`

内容はコメント `# dummy` のみ。空実装。

**判定: 利用価値なし。**

### picoruby-require

既にビルドに含まれている (`build_config/harucom-os-pico2.rb` の `conf.gem core: 'picoruby-require'`)。
`$LOAD_PATH` を `/flash` に設定済みで、`require` / `load` が動作する。

**判定: 既に利用可能。**

## マスタープランへの示唆

- Editor::Buffer をテキストエディタとIRBの行編集に採用する
- Sandbox を IRB の eval エンジンとして採用する。Machine ポート実装が前提条件
- 描画レイヤーは完全に独自実装 (DVI::Text VRAM 直接操作)
- 入力レイヤーも独自実装 (USB キーボード -> Editor::Buffer.put)
