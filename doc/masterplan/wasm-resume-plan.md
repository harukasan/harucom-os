# Harucom OS wasm 移植 — 再開プラン / ハンドオフ

新しいセッションはこのファイルを最初に読んで再開する。元の全体プランは
トランスクリプトにしか無いため、現在地と次の手をここに1枚化した。

## ゴールと方式（要約）

「Harucom OS **全体**をブラウザで**完全に**動かす（カスタム picoruby.wasm 版）」。
ファームウェアの移植可能 C をそのまま emscripten で wasm 化し、各 mrbgem に
wasm ポートを足す。**Ruby ユーザーランド（`rootfs/`）は無変更で再利用**する。
最初のマイルストーン = テキストモード OS 起動（IRB + Console + キーボード +
MEMFS が canvas 上で動き、コマンドが打てる状態）**は達成済み**。

## 現在の状態（branch: `wasm-text-mode`, `main` から26コミット先行）

```
464886a Enable Japanese IME conversion in the browser build
5fcb8b2 Tick the wasm scheduler in real time for a smoother UI
7aad1c1 Make browser keyboard input survive instant key taps
3bbfa22 Update the wasm resume plan for the Phase 2b milestone
88cb1ad Wire browser keyboard input into the OS
fccdf69 Boot the real system.rb userland in the browser
... (Phase 2a/2b 系は git log を参照)
```

未コミットの作業ツリー変更は無し（`rake wasm:test` 14/14 PASS = ブート+描画+入力+IME 辞書+グラフィックス+音声+ADC パッド）。

### 完了済み

- **Phase 0** emcc で libmruby ビルド可能を確認。
- **Phase 1** ヘッドレス起動（MEMFS rootfs deploy + VM + scheduler + stdout）。
- **Phase 1a** DVI テキストコアを共有 `src/dvi_text.c` に抽出（rp2350 と wasm が共用）。
- **Phase 2a** wasm DVI レンダラ + canvas blit。narrow/wide glyph・パレット色を検証済み。
- **コードレビュー第2パスの cleanup**（`58c593f`〜`59a0aa1`）:
  - #12 `put_string`/`_bold` を `put_string_internal(bool)` に統合。
  - #14 uni2jis テーブルを全プラットフォームで libmruby にコンパイル統一（CMake 特例除去）。
  - #15 canvas blit を commit カウンタでゲート + `requestAnimationFrame` 駆動。
  - #13 smoke テストのパレット定数に出所注記。
  - #11（`deploy_rootfs`/`init_rootfs.c` 共通化）は FS バックエンド差で過剰のため見送り。
- **Phase 2b**（`fccdf69`, `88cb1ad`）= **実 `system.rb` 起動 + キーボード入力**:
  - B-1 `build_config/harucom-wasm.rb` に gem 追加: `picoruby-editor`(core)、
    `picoruby-usb-host`、`picoruby-keyboard-input`、`picoruby-ruby-syntax`(local)。
  - B-2 USB::Host の wasm ポート新規 `mrbgems/picoruby-usb-host/ports/posix/
    usb_host_wasm.c`（`#ifdef __EMSCRIPTEN__`、5関数を C statics で実装、
    `EMSCRIPTEN_KEEPALIVE harucom_kbd_set_state(mod, k0..k5)`）。
  - B-3 `Machine.board_millis` は posix machine ポートに既存（`clock_gettime`）→ 作業不要。
  - B-4 `harucom_wasm.c` のブートを `$LOAD_PATH=["/lib"]` + `load "/system.rb"` に差替え、
    C テストバナー削除（`dvi_wasm_init()` は残す）。
  - B-5 `wasm/index.html` で DOM key → HID usage 変換 → `_harucom_kbd_set_state`。
    `_harucom_kbd_set_state` を emcc exports に追加。
  - `wasm/run_node.cjs` を実ブート検証に書換え（IRB バナー到達 + framebuffer 描画 +
    `9-7`↵→`=> 2` の E2E キーストローク）。

## アーキテクチャの要点（実装済み・把握必須）

- **ビルド**: `build_config/harucom-wasm.rb`（`MRuby::CrossBuild "harucom-wasm"`、
  `PICORB_PLATFORM_POSIX` + `PICORB_PLATFORM_WASM`、emcc/emar、microruby）。
  picoruby が各 gem の `ports/posix`/`ports/common` を自動コンパイルする。
  → **wasm ポートは `ports/posix/*.c` に置き `#ifdef __EMSCRIPTEN__` でガード**する
  （`ports/posix/dvi_wasm.c`・`ports/posix/usb_host_wasm.c` が先例）。
- **DVI**: 共有テキストコア `mrbgems/picoruby-dvi/src/dvi_text.c`（VRAM/writers/
  フォントキャッシュ/パレット）+ `ports/posix/dvi_wasm.c`（VRAM→RGB332 framebuffer
  レンダラ + canvas 用 `harucom_dvi_framebuffer/width/height/frame_count`、`dvi_wasm_init`）。
  mruby バインディング `src/mruby/dvi.c` は無変更で再利用。
- **キーボード**: `usb_host_wasm.c` が JS 注入の HID レポート（modifier + keycodes[6]）を
  C statics で保持。`USB::Host`→`Keyboard#poll`→`LineEditor`→`IRB` の Ruby パイプライン
  は全て無変更で再利用。`index.html` が `keydown`/`keyup`→HID usage→`harucom_kbd_set_state`。
- **協調 yield（設計の要）**: `DVI.wait_vsync` を `mrbgems/harucom-os-wasm/mrblib/
  dvi_wasm.rb` で `sleep_ms 16`（task-aware）に override。これが主要な yield 点。
  `sleep_ms` は **task コンテキストでのみ** yield する（root/Cフレームからは実 sleep に
  fallback してタブを固める）ため、ブート/IRB/poll ループは全て `Task.new` 内で回る。
- **FS**: emscripten MEMFS（mruby-io の File/Dir）。`harucom_wasm.c::deploy_rootfs` が
  毎ロード rootfs を再 deploy。**littlefs/VFS は使わない**（ブートで mount しない）。
- **ブート連鎖**: `harucom_init`（C）→ `picorb_create_task(ruby_bootstrap)` →
  `$LOAD_PATH=["/lib"]; load "/system.rb"`。`load` は picoruby-require 経由で
  **Sandbox タスク**内で system.rb を実行し、ブートタスクは `Sandbox#wait` の
  `sleep_ms` ループで待つ。system.rb が usb_host/keyboard タスクと IRB ループを起動。
- **JS run loop**: `wasm/index.html` が `mrb_tick_wasm`→`mrb_run_step`→（frame_count が
  進んだ時のみ）`blit`→`requestAnimationFrame`。framebuffer(RGB332)→canvas は LUT 変換。

## 再開ポイント

Phase 2b（テキストモード OS のブート + 入力）まで完了。次は順に:

### 次の作業A: ブラウザ実機での目視確認（ユーザー）

ヘッドレス（`rake wasm:test`）は通っているが canvas はこちらから見えない。
`bundle exec rake wasm:server` → `http://localhost:8000` を開き:
- IRB バナー + `irb> ` プロンプトが M+ グリフで描画されるか。
- canvas をクリックしてフォーカス → `1 + 1`↵ → `=> 2`、日本語 URL 行の全角描画。
- キーリピート（長押し）、カーソル移動、Backspace、Ctrl-C の挙動。

### 次の作業B: 残りのコードレビュー指摘（DVI 描画エッジケース）

下表の #2/#4/#5/#6。**`dvi_text.c` を触る変更は実機 DVI タイミング回帰の可能性**が
あり、ボード所有者=ユーザーに `rake distclean && rake` + 実機 FIFO underflow 確認を
依頼すること。`dvi_wasm.c` のみの変更（#6、#2/#4 のレンダラ側）はブラウザ完結で安全。

### 次の作業C: 以降のフェーズ

- **Phase 4 グラフィックス** ✅完了（`f90bd89`）: `dvi_wasm.c` で専用 `graphics_buf` に
  描画し `dvi_graphics_commit` で表示 framebuffer へ提示(scale=1 は memcpy、scale=2 は
  320×240→640×480 の2xアップスケール)。`dvi_set_mode`/`dvi_text_commit` を active_mode
  対応(モード切替のクロバー防止 + text 復帰で再描画)。`DVI::Graphics.commit` を
  `dvi_wasm.rb` で yield 化(board の vsync 待ち相当、P5 ループの凍結防止)。レビュー #3
  解消。赤矩形をヘッドレス検証。P5 デモ(`p5_demo`/`p5_game_demo`)で目視確認可。
- **音声** ✅完了（`1054773`）: `ports/posix/pwm_audio_wasm.c` が synth の ring buffer を
  `harucom_audio_pull`(planar float、0..499→-1..+1)で drain。`index.html` の
  ScriptProcessorNode(SAB不要、user gesture 起動、22050Hz/リサンプル fallback)が再生。
  実機のアナログ再構成フィルタ(R28 220Ω + C25 220n の ~3.3kHz 1次 RC LPF)を pull 内の
  1極 IIR で再現。IRB で `PWMAudio` 直叩き、または `audio_demo` で試聴可。
- **ADC パッド** ✅完了（`feeaed8`）: `harucom_wasm.c` に wasm 専用 `ADC` クラス
  (`read_raw` が JS 注入値を返す)+ `harucom_pad_set(index, raw)`。`index.html` の画面下
  D-pad ×2 が押下マスク→抵抗ラダー並列合成式(1k/2.2k/4.7k/10k)で raw を算出し注入。
  `Board::Pad` 無変更で decode。`audio_demo`(オクターブ)/`pad_demo` がブラウザで動作。
- **IME/辞書** ✅完了（`464886a`）: `harucom-os-dict` の wasm ポート
  `ports/posix/dict_region.c`（rp2350 のパースを逐語移植、XIP の代わりに可変ベース
  ポインタ + `dict_wasm_init` が `/dict.bin` を読込）。`dict.bin`(1.28MB) を emcc
  `--embed-file` で MEMFS に埋め込み。`InputMethod.dict_available?/skk_lookup/
  tcode_lookup` が解決し SKK 変換が動作（`にほん`→`日本` をヘッドレス検証）。
- **構文ハイライト**: `RubySyntax.analyze` は `picoruby-ruby-syntax`（Prism ベース C）で
  既に投入済み・稼働。

## 未対応のコードレビュー指摘（第2パス）

| # | 内容 | 箇所 | 対応時期 |
|---|---|---|---|
| 2 | stray WIDE_R 描画差異（全角左半を半角上書きで右半残り、以降の行が水平シフト）CONFIRMED・到達可。基本デモ（英語 + 静的な日本語1行）では出ない | `dvi_wasm.c:79` / 共有 writer | 全角編集を詰める時 |
| 4 | WIDE_L 最終列で 1byte OOB read/write（防御的、wasm は buffer タイト） | `dvi_text.c`(render_wide_glyph)/`dvi_wasm.c` | 任意（要ファーム検証） |
| 5 | `utf8_decode` が NUL 跨ぎ read（途中で切れたマルチバイトで 1-3byte 余分）防御的 | `dvi_text.c` | 任意（要ファーム検証） |
| 6 | 右マージン/画面外を `palette[0]` で塗る（実機は固定黒0、背景色変更時のみ相違）軽微 | `dvi_wasm.c:91` | 任意（wasm 完結・安全） |
| ~~3~~ | ~~graphics スタブ（active_mode 未読 / scale スタブ）~~ → Phase 4(`f90bd89`)で解消 | `dvi_wasm.c` | ✅完了 |

## ビルド / テスト / 検証コマンド

- 前提: **Emscripten**。`emcc --version` が通ること（無ければ `source ~/emsdk/emsdk_env.sh`）。
- `bundle exec rake wasm:build` — libmruby を emcc ビルド + リンク。**gem 追加や新規
  `MRB_SYM()` 時は `CLEAN=1 rake wasm:build`**（presym/host を再構築）。
- `bundle exec rake wasm:test` — jsdom ヘッドレス smoke（`wasm/run_node.cjs`）。
  ブート（バナー到達）・描画（framebuffer 非背景）・入力（`9-7`↵→`=> 2`）を検証。
- `bundle exec rake wasm:server` — `http://localhost:8000`、ブラウザ目視（ユーザー）。
- **ファーム回帰（共有コア変更時は必須・ボード所有者=ユーザーに依頼）**:
  `rake distclean && rake` でコンパイル + 実機で DVI FIFO underflow /
  `dvi_irq_max_cycles` を確認。**`src/dvi_text.c` を触る変更は実機 DVI タイミング
  回帰の可能性あり**（抽出で共有状態が scratch から .bss へ移った件。既知リスク）。

## 主要ファイル

- `mrbgems/harucom-os-wasm/src/harucom_wasm.c` — wasm ブート（`harucom_init`、実 system.rb 起動）
- `mrbgems/harucom-os-wasm/mrblib/dvi_wasm.rb` — `DVI.wait_vsync` yield override
- `mrbgems/picoruby-dvi/src/dvi_text.c` — 共有テキストコア（#5 対象）
- `mrbgems/picoruby-dvi/ports/posix/dvi_wasm.c` — wasm レンダラ（#2/#3/#4/#6 対象）
- `mrbgems/picoruby-dvi/src/mruby/dvi.c` — DVI バインディング（無変更で再利用）
- `mrbgems/picoruby-usb-host/ports/posix/usb_host_wasm.c` — USB::Host wasm ポート（B-2）
- `mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb` — Keyboard（無変更で再利用）
- `mrbgems/picoruby-ruby-syntax/src/ruby_syntax.c` — RubySyntax.analyze（Prism、投入済み）
- `build_config/harucom-wasm.rb` — gem 構成
- `Rakefile`（`namespace :wasm`）— build/test/server、emcc exports
- `wasm/index.html` — JS run loop / canvas blit / キーボード入力
- `wasm/run_node.cjs` — jsdom ヘッドレステスト（ブート + 描画 + 入力 E2E）
- `rootfs/system.rb` — 実ブート（USB host task → env/yaml → require libs →
  keyboard task → IRB ループ）
- `rootfs/lib/{console,irb,line_editor,keyboard_input,ruby_syntax,input_method*}.rb` — UI 層

## リスク

- **共有 `dvi_text.c` 変更の実機 DVI タイミング回帰**（コンパイル成功 ≠ タイミング OK）。
  小コミットで進め、実機検証はユーザーに依頼。
- **背景タブでの blit 浪費**は #15 の rAF 化で緩和済み。
- **IME 辞書 (`harucom-os-dict`) 未投入**: 日本語変換（SKK/T-Code）は現状 NoMethodError。
  ブート + ASCII には影響しない。
- **MEMFS 非永続**: SKK ユーザー辞書等の書込みはリロードで消える（rescue ガード済み）。
