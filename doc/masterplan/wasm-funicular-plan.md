# wasm ブラウザシェルの整理 + funicular 化 — 再開プラン / ハンドオフ

新しいセッションはこのファイルを最初に読んで再開する。`wasm/` のブラウザ側を
「命令的 Engine 層」と「反応的 Shell 層」に再設計し、Shell(canvas 周辺の chrome)を
funicular で Ruby 化する作業の、現在地・確定事実・次の手を 1 枚化した。

関連: [wasm-resume-plan.md](wasm-resume-plan.md)(wasm 移植本体のハンドオフ)。

## ゴールと方式（要約）

`wasm/` のブラウザ JS を Engine 層(命令的・JS)と Shell 層(反応的)に分離し、
**Shell(コンソール/パッド/各種コントロール等の chrome)を funicular で Ruby 記述**する。
funicular は **harucom.wasm の単一 mruby VM の中**で OS と同居するタスクとして動かす
(picoruby.wasm の二重ロードはしない)。canvas のピクセル描画と音声は性能上 JS の
Engine 層に残す。最終像 = 「ファームウェア(OS)もブラウザの画面まわりも、同一 VM の
Ruby で動く」。

## 現在の状態（branch: `wasm-funicular`）

- `wasm-text-mode` から分岐。**コミットはまだ無い**(このプラン文書のみ未追跡。作業ツリーは
  他に変更なし)。ベースラインは緑(`build/wasm/` ビルド済み、`rake wasm:test` = **21/21 PASS**、
  emcc 6.0.0 / node 利用可)。
- **計画は Phase 1〜4 まで確定済み**。前提調査も完了(下記「確認済みの事実」)。新セッションは
  再調査・再設計不要で、Phase 1 から実装に入れる。
- **再開ポイント = Phase 1 未着手**。コードは現状(488 行のブラウザ JS + index.html の
  インライン CSS)のまま。
- 確定した主な決定: 単一 VM(`picoruby-funicular` 組み込み)/ CSS は Tailwind v4 /
  Phase 4 は devtools 風のタブ付きパネル UI(ホスト `Harucom::UI::Panels`、機能は自己登録
  `Panel`、ドック位置 下/右 切替)/ UI Ruby は MEMFS ソース + `require` でホットリロード。

## ユーザー方針 / 決定事項

- **専用ブランチ `wasm-funicular`** で作業する(`wasm-text-mode` から分岐)。
- **実装順は Phase 1 → 2 → 3 → 4**: Engine 整理 + Tailwind 基盤 → funicular 組み込み検証 →
  現 chrome の funicular 化(動かす)→ UI/スタイル体系と開発インターフェースの整理(綺麗にする)。
- **単一 VM 方式**: `picoruby-funicular`(PicoGem)を harucom-wasm の build_config に
  組み込む。別 picoruby.wasm のロードはしない。
- **ボード(実機)build への波及はゼロ**を厳守: funicular gem は wasm config のみ、
  UI Ruby は wasm build のみ。

## 実装の開始手順（新セッションの最初の一歩）

1. このファイルを通読する(特に「確認済みの事実」「目標アーキテクチャ」「設計原則」)。
2. ブランチ確認: `git switch wasm-funicular`(`wasm-text-mode` から分岐済み)。
3. ベースラインを緑にする: `emcc --version`(無ければ `source ~/emsdk/emsdk_env.sh`)→
   `bundle exec rake wasm:build && bundle exec rake wasm:test`(直近 21/21 PASS)。これが
   Phase 1 の不変条件「テスト緑・挙動不変」の基準。
4. **Phase 1 から開始**(Engine の facade 化 + Tailwind 基盤。純リファクタで挙動不変)。
   Phase 1 のチェックリストを上から進める。
5. 各 Phase 末で `rake wasm:build`(Phase 2 以降は必要に応じ `distclean`)+ `rake wasm:test`
   を回し、Phase 単位でコミットする。

キックオフ用プロンプト例(新セッションの最初の発話):

> `doc/masterplan/wasm-funicular-plan.md` を読んで Phase 1(Engine の facade 化 + Tailwind
> 基盤)から実装を始めて。まず `bundle exec rake wasm:test` でベースラインが緑なのを確認してから
> 着手して。純リファクタなので挙動とテスト(21/21)は維持すること。

## 確認済みの事実（再調査不要・出所つき）

組み込み経路の前提は実ソースで確認済み。

1. **`picoruby-funicular` は純 mrblib(C ソース無し)**。submodule に既に存在
   (`lib/picoruby/mrbgems/picoruby-funicular/`、`mrblib/component.rb` `vdom.rb`
   `differ.rb` `patcher.rb` `router.rb` `store*.rb` 等)。DOM 操作は `JS` グローバル
   経由(`mrblib/patcher.rb` が `@doc.createElement` / `setAttribute` /
   `appendChild` / `addEventListener` 等を `JS` 越しに呼ぶ)。
2. **`JS`/DOM ブリッジ(`picoruby-wasm`)は harucom.wasm に既にリンク済み**。
   `build_config/harucom-wasm.rb` 末尾の `conf.gem core: "picoruby-wasm"`。
   `wasm/js/runloop.js` は既に `mrb_run_step` / `mrb_tick_wasm` を駆動している。
3. **ブリッジは全て `EM_JS`(C 内インライン JS)実装**
   (`lib/picoruby/mrbgems/picoruby-wasm/src/mruby/js.c`: `js_create_element` /
   `js_create_text_node` / `js_add_event_listener` / `js_set_timeout` / fetch /
   promise / `js_register_generic_callback` 等が揃う)。`--js-library` 等の追加
   リンクフラグは不要で、harucom の既存 emcc リンク行のまま通る。
4. **funicular のビルド依存は現状の config で全て満たせる**
   (`lib/picoruby/mrbgems/picoruby-funicular/mrbgem.rake`):
   - `picoruby-wasm`(config 内 ✅)
   - `picoruby-json`(submodule にあり + `stdlib` gembox 同梱 ✅)
   - `mruby-object-ext` / `hash-ext` / `array-ext` / `string-ext` / `metaprog`
     (`gemdir:` が `picoruby-mruby` 同梱 mruby を指す。`picoruby-mruby` は config 内 ✅)
   - `picoruby-indexeddb` は **ローカル未存在だが、ローカル mrbgem.rake の依存に
     挙がっていない**(Store 機能利用時のみ実行時に `JS` 経由で呼ぶ)。ビルド阻害なし。

結論: 組み込みの実体は「`conf.gem core: "picoruby-funicular"` 追加 + `distclean` +
再ビルド + 起動タスク追加」。VM 二重・自前ブリッジ・追加リンクといった壁は無い。

## 目標アーキテクチャ

```
┌───────────────────────────────────────────────────────────┐
│ Shell（反応的UI: Ruby/funicular, harucom.wasm の同一VM内タスク） │
│  - ConsolePane（stdout/stderr 行ログ, 自動スクロール）          │
│  - KbdDebug（最後のキー/HID/held 表示）                        │
│  - Pads（押下maskを持つ2つのDパッド → Engine.setPad）           │
│  - 将来: StatusBar(fps/underrun/frame), Controls, filer, 設定   │
│  - <canvas> は funicular の管理外の「安定リーフ」(Engineが所有)  │
└───────────────▲────────────────────┬──────────────────────┘
   on('print'/'frame'/'audio')        │  setPad / startAudio / reset
   （JSコールバック経由でRubyへ）       │  （JS bridge 経由でEngineへ）
┌───────────────┴────────────────────▼──────────────────────┐
│ Engine（命令的・フレームワーク非依存・JS, 性能ホットパス死守）    │
│  harucom.wasm + runloop(rAF→mrb_run_step/mrb_tick_wasm)       │
│  + display.blit(640x480 RGB332→canvas) + AudioWorklet pump    │
│  + 入力エンコード(HID/ADC) + MEMFS prune                       │
│  facade: createEngine(Module,{canvas}) → { start, on, setPad, … } │
└──────────────────────────────────────────────────────────┘
```

設計原則(把握必須):
- **canvas のピクセルコピー(`display.js`)と音声(`audio-worklet.js`)は毎フレーム/
  毎サンプルのホットパス**。funicular の `JS` ブリッジ越しにピクセル単位で触ると桁違いに
  遅い。これらは JS の Engine に残す。funicular は変化の遅い chrome DOM だけを所有する。
- **canvas は funicular の管理サブツリー外の安定リーフ**として据え置く(funicular が
  再 render で canvas を再生成して 2D コンテキストを破壊しないこと)。Shell は canvas の
  兄弟コンテナに chrome を描画する。

## CSS / スタイルの整理（Tailwind CSS 採用・決定）

現状の CSS は `wasm/index.html` の `<style>` にインラインで約 20 行
(`body` / `h1` / `#screen` / `#out` / `#kbddbg` / `#pads` / `.pad` / `.pad-title` /
`.padbtn` / `.padbtn.on`)。全て chrome(Shell)+ canvas 表示 + ページ基盤のスタイル。

funicular のスタイル機構(`lib/picoruby/mrbgems/picoruby-funicular/mrblib/styles.rb` +
`docs/styling.md`)の理解:
- `styles` DSL は **CSS クラス名を合成する DSL**であって CSS ルールは生成しない。
  `s.foo` は class 文字列を返し `:class` に適用する。**実 CSS ルールはスタイルシートが
  別途必要**。Tailwind 等の**ユーティリティクラス前提**の設計(公式が推奨)。
- `base:` / `active:` が現状の `.padbtn` + `.padbtn.on` トグルに一致。funicular 化で
  JS の `classList.add/remove("on")` が Ruby の `s.padbtn(pressed?)` に置き換わる。

**方針(決定): Tailwind CSS を採用する**。理由 = funicular は Ruby 側で class 名の
*文字列*を合成する設計なので、ユーティリティ文字列をそのまま消費できる Tailwind が直結する
(funicular 公式推奨・ランタイム JS ゼロ)。Panda CSS は型付き `css()`/recipe/token API が
JS/TS 専用で Ruby から呼べず、生成クラスを文字列で貼るだけなら Tailwind の劣化版になるため不採用。

```ruby
class Pads < Funicular::Component
  styles do
    padbtn base: "w-10 h-10 bg-gray-700 rounded", active: "bg-green-600"
  end
  def render
    button(class: s.padbtn(pressed?)) { "↑" }
  end
end
```

導入形態(軽量に保つ):
- **Tailwind v4 standalone CLI**(`@tailwindcss/cli`)を `wasm/package.json` の devDeps に追加
  (`wasm/` には既に npm + `package.json` があり node ツールは異物でない)。PostCSS 設定不要。
- 入力 `wasm/css/app.css`: `@import "tailwindcss";` + `@theme` でレトロ配色トークン
  (bg `#111` / text `#eee` / console green `#0f0`)+ canvas 基盤を `@layer base` に小さく手書き
  (`#screen` の `image-rendering: pixelated` / 640x480 はユーティリティ向きでないので残す)。
- `@source` で class 文字列の在処を走査対象に: `wasm/index.html`(静的 chrome、当面)と
  funicular UI の `.rb`(Phase 3 で配置先を追加)。
- 出力 `build/wasm/style.css` を `index.html` から `<link>`。`rake wasm:css`(または
  `wasm:build` に内包)で `tailwindcss -i wasm/css/app.css -o build/wasm/style.css --minify`、
  `wasm:server` は `--watch` で配信。`stage_index!` が出力を `build/wasm/` に配置。

段階導入: Phase 1 で CLI + `app.css` + ビルド配線を整え**現状の静的 chrome をユーティリティ化**
(見た目不変)。Phase 3 で funicular UI の `.rb` を `@source` に追加し、状態トグル(`.on` 等)を
`styles` DSL の `base:/active:` へ移す。1 つのスタイル系で通す。

## Phase 1: Engine の整理（funicular 非依存・純リファクタ）

目的: Shell が wasm 内部(`Module._harucom_*`)に触れずに済む facade とイベント境界を
作る。**挙動は現状と完全に同一**に保つ。現状の `wasm/js/` は責務分割が良好なので、
束ねる facade と純ロジック抽出が主作業。

- [ ] `wasm/js/engine/` を作り、デバイス系モジュールを移動
      (`display.js` `keyboard.js` `audio.js` `audio-worklet.js` `pads.js`
      `runloop.js` `fs.js`)。
- [ ] 純ロジックを DOM 非依存モジュールに抽出(host テスト可能に):
  - `engine/hid.js`: `HID` / `MOD` テーブル + `usageFor`(`keyboard.js` より)。
    テストハーネスの `hidForChar` と将来共有可能。
  - `engine/pad-ladder.js`: `PAD_CAL` / `PAD_G` / `padRaw`(`pads.js` より)。
- [ ] `engine/index.js` に facade `createEngine(Module, { canvas })` を実装:
  - 内部で display/keyboard/audio/pads/runloop を合成。
  - 公開 API: `start()` / `setPad(pad, dir, down)` / `startAudio()` /
    `on(event, cb)` / `canvas`。
  - イベント: `print`(stdout/stderr 1 行) / `frame`(frame count) /
    `audio`(level/underruns 診断)。`print` は今 `main.js` が `Module.print` で
    `#out` に直書きしている経路を facade のイベントに移す。
- [ ] `main.js` を薄い合成ルートにする: Module 生成 → `createEngine` →
      **現状の静的 DOM**(`#out` `#kbddbg` `#pads`)に結線。挙動は不変
      (Phase 3 でこの DOM 結線を funicular Shell に差し替える)。
- [ ] テスト整合: `tests/harness.cjs` は `../js/fs.js` と wasm exports を直接参照。
      `fs.js` の import パス(移動するなら 1 行修正)と export 契約を維持。
      **wasm export 名は不変**。
- [ ] CSS をインライン `<style>` から抽出し **Tailwind を導入**:
  - `wasm/package.json` に `@tailwindcss/cli` を追加。`wasm/css/app.css`
    (`@import "tailwindcss";` + `@theme` トークン + canvas 基盤の `@layer base`)を作成。
    `@source` に `wasm/index.html` を指定。
  - `Rakefile` に `wasm:css`(`tailwindcss -i wasm/css/app.css -o build/wasm/style.css
    --minify`)を追加し `wasm:build` から呼ぶ。`stage_index!` が `style.css` を配置、
    `wasm:server` は `--watch`。`index.html` から `<link>` 参照。
  - 現状の静的 chrome をユーティリティクラス化(見た目不変)。

受け入れ条件(Phase 1 完了ゲート):
- [ ] `rake wasm:build && rake wasm:test` が緑(OS コアの smoke 不変)。
- [ ] `rake wasm:server` でブラウザの表示・入力・音声・パッドが現状と同一(目視)。
- [ ] 抽出した純ロジックに node 単体テストを追加(DOM 不要)。

## Phase 2: funicular の組み込み（素通しビルド検証）

目的: harucom.wasm の VM に funicular を載せ、ビルドと最小動作を確認する。

- [ ] `build_config/harucom-wasm.rb` に `conf.gem core: "picoruby-funicular"` を追加。
- [ ] `rake distclean && rake wasm:build`(funicular のクラスで `MRB_SYM` が増えるため
      `distclean` 必須)。依存解決(json / mruby-*-ext)とリンク(EM_JS ブリッジ既存、
      追加フラグ不要のはず)が通ることを確認。
- [ ] `picoruby-indexeddb` を boot 時に参照しないこと(funicular mrblib が起動時に
      ハード依存しない)を確認。必要になったら vendor する(Store 機能利用時のみ)。
- [ ] wasm サイズの前後差を記録(funicular は純 Ruby mrblib なので増分は小さい想定)。
- [ ] 最小スモーク: この build 上で `JS.global[:document]` が機能し、
      `Funicular::Component` を 1 個生成して DOM ノードをマウントできることを確認
      (canvas 上の IRB から Ruby 片を実行、または wasm 専用テストで)。
      ブリッジ + funicular が harucom の VM で動く証明。jsdom が `JS` の DOM 操作を
      満たすかはここで判断する(満たさなければ UI 検証は当面ブラウザ目視)。

## Phase 3: プロトタイプ（現 chrome の funicular 化）

目的: 現状の chrome(コンソール + パッド + キーボードデバッグ)を funicular の
Ruby コンポーネントで再実装し、同一 VM で OS + UI が同居することを示す。

- [ ] UI Ruby の置き場所と起動を決定(下「未決事項」)。第一候補: wasm 専用 mrbgem
      `harucom-ui-wasm`(または `harucom-os-wasm` の mrblib)に置き、wasm の libmruby
      にのみコンパイル。**ボード build には含めない**。OS 起動後に別の mruby Task として起動。
- [ ] Engine↔Shell イベント橋を実装:
  - Engine→Shell: `print` / `frame` / `audio` を `picoruby-wasm` のコールバック
    (`js_register_generic_callback` 等)で Ruby に push、または毎フレームポーリングする
    JS グローバルで渡す。
  - Shell→Engine: パッド押下 → `Engine.setPad`、音声開始、reset を JS bridge で呼ぶ。
- [ ] コンポーネント実装:
  - `ConsolePane`: `print` を購読して行を追記、自動スクロール。
  - `KbdDebug`: 最後のキー/HID/held を表示。
  - `Pads`: `pads.js` の DOM 生成を置換。押下で `Engine.setPad`。
  - (任意) `StatusBar`: frame / fps / audio underruns。
- [ ] canvas を Engine 所有の安定リーフとして据え置き、Shell はその兄弟コンテナに描画。
- [ ] Tailwind の `@source` に funicular UI の `.rb` 配置先を追加し、状態トグル
      (`.padbtn.on` 等)を `styles` DSL の `base:/active:` へ移して JS の `classList`
      操作を置換。CSS ルール自体は Tailwind 生成の `style.css` に残す。

受け入れ条件:
- [ ] 見た目・操作感が現状と等価で、chrome が Ruby 記述・OS と同一 VM で動く。
- [ ] `rake wasm:test` の OS コアテストは緑のまま。
- [ ] `rake wasm:server` で目視等価。

## Phase 4: UI とスタイルの整理（タブ付きパネル UI / devtools 風）

目的: Phase 3 で動いたプロトタイプを、**devtools 風のタブ付きパネル UI** に整理し、
**今後の機能追加を「Panel を 1 つ足すだけ」**にする。OS の canvas は常時表示し、その
**下または右(切替可)**にタブ付きのパネル群(`Harucom::UI::Panels`)をドックする
(ブラウザの devtools と同じ)。各機能(Console / Pads / 将来の
Files / Audio scope / VM stats …)は自己登録する `Panel` として実装され、タブに自動で並ぶ。
コンポーネント作者は wasm 内部(`Module._harucom_*` / `JS` / `js_register_generic_callback`)に
一切触れず、funicular + Tailwind だけで書ける。以下は提案インターフェース(実装時に
funicular の実 API に合わせて微調整。イベントは `onclick: -> { … }` / ルーティングは
`Funicular.router` を確認済み)。

確認済みの funicular API: `Funicular.start(Comp, container:)` / `Funicular::Component`
(`initialize_state` / `state` / `patch(hash)` / `render` / `component(Child)` /
`component_mounted` / `mount` / `unmount`)/ `styles do … end` + `s` アクセサ。

### A. Engine の Ruby facade（device への唯一の窓口）

JS 側 Engine(Phase 1)を Ruby から使う薄い facade。`JS` ブリッジやコールバック登録を
内側に隠し、購読は unmount で自動解除する。

```ruby
module Harucom
  def self.engine = Engine.instance

  class Engine                 # picoruby-wasm の JS ブリッジを内包
    def on_print(&blk); end    # stdout/stderr 1 行
    def on_frame(&blk); end    # frame count
    def on_audio(&blk); end    # { level:, underruns: }
    def pad_set(pad, dir, down); end
    def start_audio; end
    def reset; end
  end
end
```

### B. プロジェクト共通のコンポーネント基底

```ruby
module Harucom::UI
  class Component < Funicular::Component
    def engine = Harucom.engine     # 全コンポーネントの device 窓口
    # component_mounted で登録した engine 購読を unmount で自動解除
  end
end
```

### C. Panel インターフェースとレジストリ（拡張の肝）

各機能は `Panel` を継承して**自己登録**する。機能追加 = Panel を 1 つ定義するだけで、
タブに自動で並ぶ。

```ruby
module Harucom::UI
  class Panel < Component
    class << self
      def title(t = nil); t ? @title = t : @title; end   # タブ表示名
      def slug(s = nil);  s ? @slug  = s : @slug;  end   # 識別子 / ルート
      def order(n = nil); n ? @order = n : @order; end   # タブ並び順
      def inherited(sub)
        super
        Panels.register(sub)                              # 自己登録
      end
    end
  end
end
```

### D. Panels ホスト（タブバー + アクティブパネル）

```ruby
class Harucom::UI::Panels < Harucom::UI::Component
  def self.register(panel); list << panel; end
  def self.list; @list ||= []; end
  def self.sorted; list.sort_by { |p| p.order || 999 }; end

  styles do
    bar     "flex items-center border-b border-gray-700 bg-panel-bg"
    tabs    "flex overflow-x-auto"   # タブ溢れは横スクロール（devtools 同様）
    tab     base: "px-3 py-1.5 text-sm cursor-pointer text-tab-inactive hover:text-fg whitespace-nowrap",
            active: "text-tab-active border-b-2 border-tab-border"
    dockbtn "px-2 text-tab-inactive hover:text-fg"
    body    "flex-1 overflow-auto p-3"
  end

  def initialize_state = { active: self.class.sorted.first&.slug }

  def render
    div(class: "flex flex-col h-full") do
      div(class: s.bar) do
        div(class: s.tabs) do
          self.class.sorted.map do |p|
            div(class: s.tab(p.slug == state.active),
                onclick: -> { patch(active: p.slug) }) { p.title }
          end
        end
        # ドック位置トグル。位置 state は App が持ち props[:on_dock] で切替
        div(class: "ml-auto flex") do
          button(class: s.dockbtn, onclick: -> { props[:on_dock]&.call(:bottom) }) { "⊥" }
          button(class: s.dockbtn, onclick: -> { props[:on_dock]&.call(:right) })  { "⊣" }
        end
      end
      div(class: s.body) do
        active = self.class.sorted.find { |p| p.slug == state.active }
        component(active) if active
      end
    end
  end
end
```

### E. 機能 = Panel（catalog の例）

現 chrome を Panel に載せ替える。将来の機能(Files / Audio scope / VM stats)も同じ型で
ファイルを 1 つ足すだけ。

```ruby
class ConsolePanel < Harucom::UI::Panel
  title "Console"; slug "console"; order 10
  styles { pane "bg-black text-term-green font-mono text-sm h-full overflow-y-auto p-2" }
  def initialize_state = { lines: [] }
  def component_mounted
    engine.on_print { |line| patch(lines: (state.lines + [line]).last(500)) }
  end
  def render; pre(class: s.pane) { state.lines.join("\n") }; end
end

class PadsPanel < Harucom::UI::Panel
  title "Pads"; slug "pads"; order 20
  styles { btn base: "w-10 h-10 rounded bg-pad text-lg select-none", active: "bg-pad-on" }
  # 押下で engine.pad_set(pad, dir, true)(+ engine.start_audio)。class は s.btn(pressed?)
end

class FilesPanel < Harucom::UI::Panel   # 将来: このファイルを足すだけでタブが増える
  title "Files"; slug "files"; order 30
end
```

### F. アプリ入口とレイアウト（Screen + Panels ドック、位置切替）

OS の canvas は常時表示し、`Panels` を**下/右に切り替えてドック**(devtools 同様)。ドック位置の
state は `App` が持ち、`Panels` には props で渡して切替コールバックを受ける(state は下へ、
イベントは上へ、の funicular 流)。

```ruby
class Harucom::UI::App < Harucom::UI::Component
  styles do
    col  "h-screen bg-base text-fg flex flex-col"   # dock=:bottom（main 上 / dock 下）
    row  "h-screen bg-base text-fg flex flex-row"   # dock=:right （main 左 / dock 右）
    main "flex-1 grid place-items-center p-4 min-h-0 min-w-0"
    dock_bottom "h-64 border-t border-tab-border overflow-hidden"
    dock_right  "w-96 border-l border-tab-border overflow-hidden"
  end

  def initialize_state = { dock: :bottom }          # :bottom | :right（将来 :left / undock）

  def render
    bottom = state.dock == :bottom
    div(class: bottom ? s.col : s.row) do
      div(class: s.main) { component(Harucom::UI::Screen) }   # Engine 所有 canvas の安定リーフ
      div(class: bottom ? s.dock_bottom : s.dock_right) do
        component(Harucom::UI::Panels, props: { on_dock: ->(pos) { patch(dock: pos) } })
      end
    end
  end
end

Funicular.start(Harucom::UI::App, container: "app")
```

`Screen` は Engine 所有の `<canvas>` を一度だけ取り込み、内部を再 render しない安定リーフ
(funicular に canvas を再生成させない)。main と dock の間のドラッグ・リサイズ・スプリッタ
(devtools 同様)は近い将来の拡張。タブのルート連動は `Funicular.router`(`#/console` 等)で任意。

### G. デザイントークン（Tailwind `@theme`）

タブ付きパネル UI に必要なセマンティックトークン(タブ active/inactive/border、パネル背景、
フォーカス)を名前付きで定義し、各 Panel の class を意味的に保つ。

```css
@theme {
  --color-base: #111;  --color-fg: #eee;  --color-term-green: #0f0;
  --color-pad: #333;   --color-pad-on: #0a0;
  /* タブ/パネル/ドック */
  --color-tab-active: #eee;   --color-tab-inactive: #888;
  --color-tab-border: #0f0;   --color-panel-bg: #1a1a1a;  --color-focus: #0f0;
}
```

→ `bg-base` / `text-tab-inactive` / `border-tab-border` / `bg-panel-bg` 等が使える。共通の
ボタン等は funicular の style mixin(`include Harucom::UI::Styles::Button`、`styling.md` の
"Extract Common Styles" パターン)で共有する。

### H. 速い開発ループ（DX の肝）

UI の Ruby を **libmruby に焼き込まず MEMFS にソース配置して `require`** する(rootfs と
同じ仕組み)。こうすると **UI 反復 = `.rb` 編集 → 再ステージ → リロード**で済み、emcc/
libmruby の再ビルドが要らない。`rake wasm:server` は Tailwind `--watch` + `wasm/ruby/`・
`js/`・`css` の再ステージを兼ねる。フルビルドは funicular/picoruby-wasm の gem 自体を
変えた時だけ。

### I. 参考: ブラウザの Web インスペクター（devtools・依存はしない）

レイアウトと操作感はブラウザの devtools を参照する。借りる中心は **ドック位置の切替**
(下/右、将来 左/別ウィンドウ)、main と dock の **ドラッグ・リサイズ・スプリッタ**、
**タブ行 + 溢れ時のスクロール/オーバーフロー**、被検査対象(canvas)が dock 移動で
リサイズされる点。実体ライブラリには依存しない(funicular は Ruby でオーサリングするため
JS/TS 製コンポーネントキットは Panda と同じ理由で不適。VS Code の公式トールキットも
2025-01 にアーカイブ済み)。アイコンが要るときは MIT のアイコンフォント(Codicons 等)を
静的アセットとして使う(JS 不要)。

### タスク

- [ ] `Harucom::Engine` Ruby facade を実装(JS Engine 購読/コマンドの薄いラッパ、
      unmount で購読解除)。
- [ ] `Harucom::UI::Component` 基底 + `Panel` 基底 + `Panels` ホスト(タブバー +
      自己登録レジストリ)を実装。
- [ ] 現 chrome を Panel 化(`ConsolePanel` / `KbdDebugPanel` / `PadsPanel` /
      `StatusPanel`)。Phase 3 の素朴な実装をここに寄せる。
- [ ] `@theme` デザイントークン + 共通 style mixin を定義し、各 Panel の class を
      トークン経由に。
- [ ] `Harucom::UI::App`(Screen + Panels ドック、**ドック位置 下/右 切替**)+
      `Funicular.start` 入口に集約。(任意: スプリッタでリサイズ、タブの `Funicular.router` 連動)
- [ ] UI Ruby を MEMFS ソース配置 + `require` 化し、`rake wasm:server` を
      `.rb`/`.css` ホットリロード対応に。

受け入れ条件:
- [ ] **新機能 = Panel を 1 ファイル足すだけでタブに出る**(JS / wasm ビルド / 他 Panel に
      触れず)。
- [ ] **ドックを下/右に切り替えられ**、canvas 側がそれに追従してレイアウトされる。
- [ ] UI/スタイルの反復が emcc 再ビルドなしで回る(編集 → リロード)。
- [ ] `rake wasm:test` の OS コアテストは緑のまま。

## テスト戦略

- OS コアの `.cjs` smoke(`wasm/tests/*.test.cjs`)は funicular に触れないので全 Phase で
  緑を維持。
- Phase 1 で抽出した `hid` / `pad-ladder` の純ロジックは node 単体テスト(DOM 不要)。
- funicular の UI 層は jsdom が `JS` ブリッジの DOM 操作を満たすか不確実。満たさない場合は
  当面 `rake wasm:server` での目視 + 将来 Playwright。判断は Phase 2 の最小スモークで得る。

## ビルド / テスト / 検証コマンド

- 前提: **Emscripten**。`emcc --version` が通ること(無ければ `source ~/emsdk/emsdk_env.sh`)。
- `bundle exec rake wasm:build` — libmruby を emcc ビルド + リンク。`index.html` / `js/` のみの
  変更は `rake wasm:server` の `stage_index!` で反映(リビルド不要)。
- `bundle exec rake wasm:css`(Phase 1 で追加)— Tailwind CLI で `wasm/css/app.css` →
  `build/wasm/style.css` を生成(`--minify`)。`wasm:build` から呼ぶ。`wasm:server` は
  `--watch` で配信。`@source` が走査する class 在処(`index.html` / funicular `.rb`)の
  変更で再生成。`stage_index!` が `style.css` を `build/wasm/` に配置。
- **`rake distclean && rake wasm:build`** — **gem 追加・新規 `MRB_SYM()`・`conf.cc.defines`
  追加時は必須**(presym/host を再構築)。**Phase 2 の funicular gem 追加はこれに該当**。
  `CLEAN=1 rake wasm:build` でも `WASM_BUILD`/`WASM_HOST` は消えるが、presym 全体の確実な
  再構築は `distclean`。
- `bundle exec rake wasm:test` — jsdom ヘッドレス smoke(`wasm/tests/*.test.cjs`、node:test、
  ファイル毎に VM ブート)。JS 音声経路(AudioWorklet/pump)と funicular UI は jsdom で
  非検証 → ブラウザ目視が必要。
- `bundle exec rake wasm:server` — `http://localhost:8000`、ブラウザ目視(ユーザー)。
- **ボード(実機)build には触れない**: funicular は wasm config のみ。実機回帰は本作業では不要
  (共有 C コアを変更しない限り)。

## 主要ファイル

現状の Engine(整理対象):
- `wasm/js/main.js` — VM 起動 + 各モジュール配線(合成ルート)
- `wasm/js/runloop.js` — rAF→`mrb_tick_wasm`/`mrb_run_step`、frame_count 進行時のみ blit
- `wasm/js/display.js` — framebuffer(RGB332)→canvas blit(LUT 変換)
- `wasm/js/keyboard.js` — DOM key→HID usage→`harucom_kbd_set_state`(`HID`/`MOD` テーブル)
- `wasm/js/audio.js` + `wasm/js/audio-worklet.js` — synth ring→AudioWorklet、時間ベース pump
- `wasm/js/pads.js` — 画面下 D-pad×2→抵抗ラダー raw→`harucom_pad_set`(`padRaw`)
- `wasm/js/fs.js` — MEMFS の `/home`/`/tmp`/`/proc` 除去(`pruneRuntimeDirs`、test も import)
- `wasm/index.html` — マークアップ(`#screen` canvas / `#out` / `#kbddbg` / `#pads`)。
  インライン `<style>` は Phase 1 で `wasm/css/app.css` へ抽出 + `style.css` を `<link>`
- `wasm/css/app.css` — Tailwind 入力(Phase 1 新規。`@import "tailwindcss"` + `@theme`
  トークン + canvas 基盤 + `@source`)。出力は `build/wasm/style.css`
- `wasm/package.json` — node devDeps(jsdom + Phase 1 で `@tailwindcss/cli` 追加)
- `wasm/tests/harness.cjs` + `*.test.cjs` — node:test smoke(`../js/fs.js` を import、
  wasm exports を直接呼ぶ。export 契約を壊さないこと)

funicular / ブリッジ(submodule、組み込み対象):
- `lib/picoruby/mrbgems/picoruby-funicular/mrblib/*.rb` — funicular 本体(純 mrblib。
  `component.rb` `vdom.rb` `differ.rb` `patcher.rb` `router.rb` `store*.rb` 等)
- `lib/picoruby/mrbgems/picoruby-funicular/mrbgem.rake` — 依存定義(上「確認済みの事実」4)
- `lib/picoruby/mrbgems/picoruby-wasm/mrblib/js.rb` + `src/mruby/js.c` — `JS`/DOM ブリッジ
  (EM_JS 実装、include/wasm.h)
- `lib/picoruby/mrbgems/picoruby-funicular/docs/architecture.md` — funicular 設計
  (Component/VDOM/Differ/Patcher/Store/SSR)

組み込み先 / 起動:
- `build_config/harucom-wasm.rb` — gem 構成。末尾に `picoruby-funicular` を追加(Phase 2)
- `mrbgems/harucom-os-wasm/src/harucom_wasm.c` — wasm ブート(`harucom_init`)。UI タスク
  起動フックの候補
- `mrbgems/harucom-os-wasm/mrblib/` — wasm 専用 mrblib。UI Ruby の置き場所候補
  (別 gem `harucom-ui-wasm` を切る案もあり)
- `Rakefile`(`namespace :wasm`) — build/test/server、emcc exports

## リスクと対策

- **funicular の未成熟**(★21・2025 開始・安定版なし)。対策: プロトタイプは小さく、
  submodule は既知コミット固定、必要なら自前パッチ前提。
- **単一 VM のスケジューラ共有**。UI タスクが OS を飢えさせないよう yield 前提。既存の
  opcode 予算プリエンプション(`MRB_USE_DEBUG_HOOK`)と per-frame バッチ
  (`runloop.js` `STEPS_PER_FRAME`)に乗せ、UI の 1 フレーム作業量を抑える。
- **性能境界**。毎ピクセル/毎サンプルを `JS` ブリッジに通さない。blit と音声は JS 据え置き。
- **build hygiene**。gem 追加で `distclean` 必須。
- **ボード build への波及ゼロ**を厳守(funicular gem は wasm config のみ、UI Ruby は
  wasm build のみ)。
- **jsdom + funicular DOM の不確実性**。ヘッドレスで UI を検証できない可能性(Phase 2 で判断)。

## 未決事項（着手時に決める）

- UI Ruby の置き場所と起動方法。**Phase 4-F の推奨 = MEMFS ソース配置 + `require`**
  (rootfs と同じ仕組み、emcc 再ビルド不要で反復)。funicular framework 自体は gem として
  libmruby に入る。別 Task としての起動フックは要設計。
- Engine→Shell のイベント転送(コールバック push かポーリングか)。
- `#out` デバッグ枠を funicular コンポーネントとして残すか、リッチなコンソールに統合するか。
- `picoruby-indexeddb` の vendor(Store 機能を使う場合のみ)。
- Tailwind の `@source` 走査対象となる funicular UI `.rb` のソースが、css ビルド時に
  ディスク上に存在すること(mrbc コンパイル後もソースは残る)を Phase 3 で確認。
- レトロ配色を `@theme` トークンでどこまでモデル化するか(Phase 1 で確定)。

## 進め方

Phase 1 → 2 → 3 → 4 の順。各 Phase 末で `rake wasm:build`(Phase 2 以降は必要に応じ
`distclean`)と `rake wasm:test` を回し、ブランチ `wasm-funicular` に Phase 単位で
コミットする。Phase 1=Engine+CSS 基盤、2=funicular 組み込み検証、3=現 chrome の
funicular 化(動かす)、4=UI/スタイル体系と開発インターフェースの整理(綺麗にする)。
