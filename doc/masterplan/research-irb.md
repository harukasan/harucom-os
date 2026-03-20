# IRB 独自実装の要素

## 調査結果サマリー

picoruby-shell の `run_irb()` メソッドは IRB の完全な実装パターンを示している。
複数行入力の検出は Sandbox.compile による try-compile で実現されている。
mruby コンパイラに「不完全な式」を検出する専用 API はなく、コンパイル試行が唯一の方法。

## 詳細

### 既存 IRB 実装のロジック

ファイル: `lib/picoruby/mrbgems/picoruby-shell/mrblib/shell.rb` (run_irb メソッド, 約50行)

IRB のコアロジック:

1. Sandbox を初期化 (`Sandbox.new('irb')`)
2. 初期コードをコンパイル・実行 (`sandbox.compile("_ = nil")`)
3. エディタの入力ループで文字を受け取る
4. Enter キー押下時:
   - バッファが空なら改行だけ出力
   - `quit` / `exit` ならループを抜ける
   - それ以外: 複数行判定 -> 実行 -> 結果表示

### 複数行入力の検出方法

```ruby
if buffer.lines[-1][-1] == "\\" || !sandbox.compile("begin; _ = (#{script}); rescue => _; end; _")
  # 継続入力 (バックスラッシュ末尾 or コンパイル失敗)
  buffer.put :ENTER
else
  # 完全な式 -> 実行
  sandbox.execute
  sandbox.wait(timeout: nil)
  sandbox.suspend
end
```

判定ロジック:
- 行末が `\` なら明示的継続
- `"begin; _ = (#{script}); rescue => _; end; _"` でコンパイル試行
  - 成功 (true): 完全な式 -> 実行
  - 失敗 (false): 構文エラー = 式が不完全 -> 入力継続

`begin...rescue...end` で囲むことで、実行時エラーではなく構文エラーのみを検出する。

### 結果表示

```ruby
if sandbox.result.is_a?(Exception)
  puts "#{sandbox.result.message} (#{sandbox.result.class})"
else
  puts "=> #{sandbox.result.inspect}"
end
```

- 例外: `message` と `class` を表示
- 正常値: `inspect` で文字列化して `=> ` 接頭辞付きで表示

### mruby コンパイラ API

ファイル: `lib/picoruby/mrbgems/mruby-compiler2/include/mrc_compile.h`

```c
mrc_irep *mrc_load_string_cxt(mrc_ccontext *c, const uint8_t **source, size_t length);
```

- 成功時: `mrc_irep*` (中間表現) を返す
- 構文エラー時: `NULL` を返す
- 「不完全な式」を検出する専用 API はない

Sandbox の `compile()` メソッドはこの関数をラップしている。

### IRB 独自実装に必要なコンポーネント

1. **入力ループ**: USB キーボードからの文字をポーリングし、Editor::Buffer に渡す
2. **プロンプト表示**: DVI::Text で行頭にプロンプト文字列を描画
3. **複数行判定**: Sandbox.compile による try-compile (上記ロジック)
4. **実行**: Sandbox.execute + wait + result 取得
5. **結果表示**: DVI::Text で結果文字列を描画
6. **ヒストリ**: 配列に入力を保存、上下キーで切り替え
7. **スクロール**: 画面末端に到達したら上にスクロール

## マスタープランへの示唆

- IRB のコアロジックは約50行の Ruby で実装可能
- Sandbox + Editor::Buffer の組み合わせが基本アーキテクチャ
- Machine モジュールのポート実装が Sandbox 利用の前提条件
- 描画は DVI::Text API を直接使う独自レイヤー
- inspect メソッドは mruby 標準で利用可能
