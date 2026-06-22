# Harucom OS wasm 移植 — 再開プラン / ハンドオフ

新しいセッションはこのファイルを最初に読んで再開する。元の全体プランは
トランスクリプトにしか無いため、現在地と次の手をここに1枚化した。

## ゴールと方式（要約）

「Harucom OS **全体**をブラウザで**完全に**動かす（カスタム picoruby.wasm 版）」。
ファームウェアの移植可能 C をそのまま emscripten で wasm 化し、各 mrbgem に
wasm ポートを足す。**Ruby ユーザーランド（`rootfs/`）は無変更で再利用**する。
最初のマイルストーン = テキストモード OS 起動（IRB + Console + キーボード +
MEMFS が canvas 上で動き、コマンドが打てる状態）**は達成済み**。

## 現在の状態（branch: `wasm-text-mode`, `main` から37コミット先行）

```
c3bacbe Add headless audio spectral measurement tools
6fc42d2 Declick note on/off with a synth attack/release ramp
2676e9b Document why the audio DC-block corner cannot be lowered
6eb0448 Make browser audio flow control time-based and add diagnostics
7f6b808 Add a headless gate for the audio underrun-boundary glitch
71f3fb1 Stop audio filter corruption on ring underrun
de161ae Linear-interpolate resampled audio to cut sine-wave noise
288db32 Remove the audio DC offset with a DC-blocking high-pass
ad08a2d Play browser audio on an AudioWorklet to stop the glitches
1566f70 Decouple browser audio from main-thread jitter with a JS ring buffer
e879366 Fix choppy browser audio (block size and render pacing)
a58fd24 Make the wasm scheduler preemptive like the board
... (Phase 2a/2b/4・IME・音声・パッド系は git log を参照)
```

**未コミットの作業ツリー変更が1つ残る**（square/saw アンチエイリアス = polyBLEP の
`pwm_audio.c`。**ユーザー判断で実機音確認まで保留中**。下記「次セッションの最優先」と
「音声」節に詳細）。計測足場（measure 関数 / Rakefile exports / `*.cjs` / doc）は
`c3bacbe` でコミット済み。`rake wasm:test` **18/18 PASS** = ブート+描画+入力+
プリエンプション+IME 辞書+グラフィックス+音声(合成/フィルタ/underrun ガード/
note-off declick)+ADC パッド。

```
M mrbgems/picoruby-pwm-audio/src/pwm_audio.c                # ★polyBLEP square/saw（共有=実機影響、保留中）
```

### このセッションで追加した作業（プリエンプション + 音声を一通り）

- **プリエンプティブ・スケジューラ**（`a58fd24`）: 実機は 1ms タイマ割込で
  `mrb->task.switching` を立てて opcode 毎にプリエンプトする。ブラウザのメインスレッドは
  割込めないので、`MRB_USE_DEBUG_HOOK` を有効化し `harucom_wasm.c` の
  `preempt_hook`（`code_fetch_hook`、opcode を数えて `PREEMPT_OP_BUDGET=30000` 毎に
  `task.switching=TRUE`）で時分割を模倣。純計算ビジーループ（yield 無し）でもタブが
  固まらない。`build_config/harucom-wasm.rb` に `conf.cc.defines << "MRB_USE_DEBUG_HOOK"`。
  **新規 struct/define を含む層なので CLEAN ビルド**。
- **描画ループのペーシング併用**（`e879366`、`dvi_wasm.rb`）: プリエンプションだけだと
  `audio_demo`/`pad_demo`/p5 が毎反復で `DVI::Text/Graphics.commit`（全画面描画）を最大速度で
  回し、同一スレッドの音声を枯渇させる。`commit` を 1 フレーム yield 化して 60fps に
  ペーシング（実機の DMA 60fps スキャン相当）。hook は freeze 防止、commit-yield は描画
  ループのペーシング、と役割分担（両方必要）。
- **音声パイプラインを作り直し**（下記「音声」節に詳細）: ScriptProcessor →
  **AudioWorklet**（専用オーディオスレッド、メインスレッド VM のジッタに非依存）。
  時間ベースのフロー制御 + JS ソース FIFO + 線形補間リサンプル。C 側は
  **DC ブロッキング HPF**(C27 相当)・**underrun でフィルタ状態を汚さない**・
  **synth に attack/release エンベロープ**(note on/off の DC 段差クリック除去)。

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

Phase 2b + グラフィックス + IME + 音声 + パッド + プリエンプションまで完了。

### 次セッションの最優先（音声の仕上げ）

**前提（このセッションで判明・解決済み）**: 当初「sine の残ノイズ -23dB」としていたが、
これは **underrun で汚れた計測値**だった。クリーンに測り直すと **sine は -42dB**（256点
sin LUT の位相切詰めによる軽微なスプリアスのみ、十分静か）。一方ユーザー指摘どおり
**square/saw こそが耳障り**で、原因は**ナイーブ（非帯域制限）合成のエイリアシング**。
理想帯域制限基準が -87dB なのに実測 -15dB（= ほぼ 100% がエイリアス）。これは synth 共有
コードなので**実機でも同一**。`wasm/measure_audio.cjs`(スペクトル) と `proto_antialias.cjs`
(手法比較) で確定し、独立検証エージェント3つが HIGH 信頼度で一致。

1. **square/saw に polyBLEP を適用 ✅実装+ヘッドレス検証済み（未コミット・実機未確認）**:
   `src/pwm_audio.c` の `generate_waveform` に `poly_blep`/`bipolar_to_amp` ヘルパを追加し、
   SQUARE/SAWTOOTH を 2点 polyBLEP で帯域制限（SINE/TRIANGLE は変更せず）。本物の C synth で
   検証: square A4 -43.4dB / G5 -19.5→**-39.6dB** / G6 -15.6→**-39.6dB**（約20dB改善、
   ファミコン級の目標達成）。`rake wasm:test` **18/18 PASS**（矩形波の発振 spread=1.65 維持、
   RC 平滑/sine/note-off declick も健全）。**残: ユーザー作業 = (a) 実機ハードでの音確認**
   （共有 synth を変えた = 実機音も変わる。DVI FIFO underflow 回帰も併せて確認）**と (b) コミット**
   （`pwm_audio.c` が主役。`pwm_audio_wasm.c`/`Rakefile`/`measure_*.cjs` は計測足場で別コミット
   可）。コスト: Core 0 の fill 経路で ~10-20 cycle/sample 増（ISR/DVI 非経路、実機 ISR は
   事前レンダ済みフレームを pop するだけなのでタイミング影響なし）。
2. **（任意・要ユーザー承認）sine も改善するか**: sine は -42dB で既に静かだが、更に詰めるなら
   **sin LUT 線形補間**で -72dB 程度まで可能（共有 synth=実機影響、ユーザーは未要望）。
3. **計測足場 ✅コミット済み（`c3bacbe`）+ doc 化済み**: `harucom_audio_measure_*` /
   `measure_audio.cjs` / `proto_antialias.cjs` は音声回帰ツールとして残す方針（ユーザー判断）。
   使い方は [doc/wasm-audio-measurement.md](../wasm-audio-measurement.md) に記述。
4. **診断ログの削除**: `index.html` の `setInterval(... "audio diag: ..." ...)`
   （`6eb0448` で追加）はデバッグ用。音声確定後に削除する。
5. ブランチ統合: `wasm-text-mode` → `main` の取り込み（ユーザー判断）。

次の順序（以降）:

### 作業A: ブラウザ実機での目視確認 ✅完了（ユーザー確認済み）

ユーザーがブラウザで動作確認済み: IRB 描画・キーボード入力（space/SandS/キーリピート/
Ctrl 系含む）・日本語 IME 変換・グラフィックス（p5 デモ）・音声（`audio_demo`、合成/
note-off declick）・ADC パッドが動作。Linux Firefox では Ctrl-Q をブラウザが奪うため
`about:config` の `browser.quitShortcut.disabled=true` を案内済み。残る音声の仕上げ
（square/saw の polyBLEP は実装済み・未コミット、要実機音確認）は「次セッションの最優先」に集約。

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
- **音声** ✅ほぼ完了（合成〜再生は安定。square/saw のエイリアシングも polyBLEP で解消済み・
  未コミット。残: コミットと実機音確認）。経緯が長いので
  最終アーキテクチャを記す:
  - **再生経路 = AudioWorklet**（`index.html`、`ad08a2d`/`6eb0448`）。`process()` が
    専用オーディオスレッドで動き、メインスレッド VM のジッタにブロックされない（=途切れ
    解消）。worklet は自前リングを持ち、サンプルは `postMessage` で渡す（**SAB/COOP-COEP
    ヘッダ不要**）。**ScriptProcessor は使わない**（メインスレッド実行でグリッチした）。
  - **フロー制御 = 時間ベース**（`6eb0448`）。pump は「前回 pump からの経過実時間 × rate」
    分 + 目標バッファへの緩い補正を供給。worklet の残量報告に依存しないので、VM が忙しく
    報告が遅延しても worklet が枯渇しない（level だけで決めると供給が止まり「ブツブツ」
    になった）。`TARGET=3072`(~140ms)。`index.html` に毎秒の診断ログ
    `audio diag: level/underruns/...`（**確認後に削除すること**、下記次の作業）。
  - **JS ソース FIFO + 線形補間リサンプル**（`de161ae`）。ctx が 22050Hz なら ratio=1 で
    無補間（実機は honor される）。22050 でない時のみ線形補間（最近傍だと純音に
    エイリアシング）。連続位相を保持しコールバック境界でフレームを落とさない。
  - **C 側 `pwm_audio_wasm.c`**: `harucom_audio_pull` が synth リングを planar float へ。
    実機アナログ出力段を再現: **R28/C25 ~3.3kHz 1次 RC LPF**（PWM 再構成）→
    **C27 DC ブロッキング HPF**（`288db32`、`AUDIO_DCBLOCK_R=0.999`≈3.5Hz）。
    DC ブロックは固定中点減算では不可（synth の無音は duty 0 で巨大な -1.0 オフセットに
    なる）。**0.16Hz まで下げると音中の DC が残り高音量でクリップ**するので 3.5Hz 固定
    （`2676e9b` に理由）。**underrun 時はフィルタを進めず無音だけ出力**（`71f3fb1`、
    JS pump が `pull(1024)` でリング 1023 を超過 pull → 不足分の 0 を HPF に通すと状態が
    汚れ次サンプルがグリッチしていた）。
  - **synth `pwm_audio.c`/`pwm_audio.h` に attack/release エンベロープ**（`6fc42d2`、
    **共有コード = 実機にも影響**、ユーザー承認済み）。note を瞬時 on/off すると符号なし
    波形の DC が段差→クリック(「プツッ」)。各チャンネルにゲイン(0..`ENV_MAX`=4096)を持ち
    `tone` で MAX へ・`stop`/`mute` で 0 へ ~2.9ms(`ENV_STEP=64`)ランプし、波形全体
    (DC 込み)をフェード。note-off の最大段差が 0.18→0.028 に。
  - **検証**: ヘッドレス `verifyAudio`(`run_node.cjs`)が 矩形波の発振・RC 平滑・
    **sine の underrun 境界グリッチ無し(`sineMaxDelta<0.08`)**・**note-off declick
    (`offMaxDelta<0.08`)** を確認。試聴は IRB `PWMAudio` 直叩き or `audio_demo`。
  - **エイリアシング対策 = polyBLEP（square/saw、実装+検証済み・未コミット）**: ユーザー
    指摘の「square G5 等が耳障り」の原因はナイーブ合成のエイリアシング（実機と同一）。
    `src/pwm_audio.c::generate_waveform` の SQUARE/SAWTOOTH を **2点 polyBLEP** で帯域制限
    （エッジの真の小数位置に帯域制限ステップ残差を足す）。`poly_blep(t,dt)`/`bipolar_to_amp(v)`
    の static inline を追加。**SINE/TRIANGLE は無変更**（sine は -42dB で十分静か、triangle の
    エイリアスは穏やかで PolyBLAMP が必要なため見送り）。本物の synth で square G5/G6 が
    -39.6dB（約20dB改善、ファミコン級）、`rake wasm:test` 18/18 PASS。
    手法選定の根拠: `proto_antialias.cjs` で naive / polyBLEP-2点 / oversample 2x-4x-8x /
    理想 を比較し、polyBLEP-2点が musical range 全域で ~-40dB フラット・最安・ISR/DVI 非影響で
    最良だった（oversample は重く効果も劣る）。**残作業はコミットと実機音確認のみ**（最優先節 1）。
    ※ wasm RC LPF の実効カットオフは alpha 近似で ~2.3kHz とやや低め（実機 3.3kHz より僅かに
    こもる）。忠実度を詰めるなら係数見直しの余地あり（エイリアスとは無関係、優先度低）。
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
- `bundle exec rake wasm:build` — libmruby を emcc ビルド + リンク。**gem 追加・新規
  `MRB_SYM()`・`conf.cc.defines` 追加・共有 struct のレイアウト変更時は
  `CLEAN=1 rake wasm:build`**（presym/host を再構築）。`index.html` のみの変更は
  `rake wasm:server` の `stage_index!` で反映（リビルド不要）。
- `bundle exec rake wasm:test` — jsdom ヘッドレス smoke（`wasm/run_node.cjs`、**18 gate**）。
  ブート(3)・描画(3)・入力(1)・プリエンプション(1)・IME 辞書(1)・グラフィックス(2)・
  音声(synth 発振/RC 平滑/sine underrun グリッチ無し/note-off declick = 4+)・
  ADC パッド(1)。JS 音声経路(AudioWorklet/pump)は jsdom で実行されないので
  ヘッドレス非検証 → ブラウザ目視が必要。
- `bundle exec rake wasm:server` — `http://localhost:8000`、ブラウザ目視（ユーザー）。
- **ファーム回帰（共有コア変更時は必須・ボード所有者=ユーザーに依頼）**:
  `rake distclean && rake` でコンパイル + 実機で DVI FIFO underflow /
  `dvi_irq_max_cycles` を確認。**`src/dvi_text.c` を触る変更は実機 DVI タイミング
  回帰の可能性あり**（抽出で共有状態が scratch から .bss へ移った件。既知リスク）。

## 主要ファイル

- `mrbgems/harucom-os-wasm/src/harucom_wasm.c` — wasm ブート（`harucom_init`、実 system.rb 起動）、
  wasm `ADC` クラス、**`preempt_hook`（opcode-budget プリエンプション）**
- `mrbgems/harucom-os-wasm/mrblib/dvi_wasm.rb` — `DVI.wait_vsync` + `DVI::Text/Graphics.commit`
  の 1 フレーム yield（描画ループのペーシング）
- `mrbgems/picoruby-pwm-audio/src/pwm_audio.{c,h}` — 共有 synth。**attack/release エンベロープ**
  （`env`/`env_target`/`ENV_MAX`/`ENV_STEP`、note on/off declick）+ **polyBLEP square/saw
  アンチエイリアス**（`poly_blep`/`bipolar_to_amp`、**未コミット・実機確認まで保留**）。いずれも実機にも影響
- `mrbgems/picoruby-pwm-audio/ports/posix/pwm_audio_wasm.c` — `harucom_audio_pull`、
  RC LPF + **DC ブロッキング HPF**、**underrun でフィルタ状態を保持** + 計測専用
  `harucom_audio_measure_tone`/`harucom_audio_measure_pull`（`c3bacbe` でコミット済み）
- `wasm/measure_audio.cjs` — スペクトル計測（FFT/Blackman-Harris/倍音・非倍音分離、`c3bacbe`）
- `wasm/proto_antialias.cjs` — アンチエイリアス手法比較プロト（naive/polyBLEP/oversample、`c3bacbe`）
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
- **共有 synth（`pwm_audio.c`）の変更が実機の音にも影響**: (1) エンベロープ（note on/off が
  ~2.9ms フェード、クリック除去、承認済み・コミット済み）、(2) **polyBLEP square/saw**
  （エイリアス除去、実装済み・未コミット）。後者は波形を float 演算で帯域制限するため、実機の
  音色が滑らかになる方向に変わる。**実機での音確認と DVI FIFO underflow 回帰確認をユーザーに
  依頼**（synth は Core 0 の fill 経路で動き ISR/DVI 非経路だが、共有コア変更につき念のため）。
  `MRB_USE_DEBUG_HOOK` を実機ビルドにも入れるかは別途判断（プリエンプション hook は wasm 専用、
  実機はタイマ割込なので不要）。
- **音声のレイテンシ ~140ms**（worklet TARGET=3072）。ジッタ耐性とのトレードオフ。
  気になるなら TARGET を下げる（枯渇リスク増）。
- **背景タブでの blit 浪費**は #15 の rAF 化で緩和済み。
- **MEMFS 非永続**: SKK ユーザー辞書等の書込みはリロードで消える（rescue ガード済み）。
