# research 08: all-pattern 化 (control pattern への統一)

## 目的

DSL を Strudel/Tidal と同じ「すべては control pattern (値が control map の Pattern)」に
統一する。masterplan「光と音の同期」節の元設計 (1 回の query を Hap の value (Hash) の
キーで音/DMX の 2 シンクへ振り分ける) への回帰であり、M4/M8 で性能理由から逸れた
「トラック分離 + 連続 signal 専用経路」を、全離散化 + chunk staging + 最適化ラダーで
置き換える。この上に M10 の序破急語彙 (jo/ha/kyu) をショー定義モジュールとして構築する。

## 決定ログ (2026-07-08)

- **all-pattern に全振り**。配線を外に出す中間コンポーネント (Program/Phrase 等の新名詞) は
  導入しない。命名問題はこれで解消
- **音エンジンの最適化 (M5/M6) を先に行う** (research 02)。理由:
  1. staging スパイクの最初の被害者は音。リングバッファ約 46ms を Ruby が充填しており、
     M8 改善後も最悪 tick 135ms で予算超過 (= M9 残課題「eval 中の音乱れ」の正体)。
     DMA ペーシング + バッファ自律化で許容遅延を広げれば GC 再戦リスクが大きく下がる
  2. M6 の sample_clock + C 側予約で、ディスパッチャが「音 = C に予約 / 光 = フレーム
     時刻に書込」の対称形になり、早撃ちハック (audio_latency_ms) が縮小する
  3. audio-ISR ジッタのクリック・整数 µs タイマ由来の +0.78% ピッチ誤差という既知バグの
     修正でもある
  4. ベンチ地盤を先に固め、all-pattern の計測・調整を一度で済ませる
- **jo/ha/kyu は一般的な名前ではないため `/data/johakyu/` のショー定義モジュール限定**。
  `rootfs/lib/johakyu/` は汎用フレームワークに留める
- 演出の時間構造は本来の序破急のまま (序=基本型を単体プレイ、破=型を組み合わせた展開
  (円運動など)、急=独自の展開を重ねてクライマックス)

## 前提

- 先に読む: [masterplan-johakyu.md](masterplan-johakyu.md)、research 02 (音)、04 (パターン
  コア)、05 (DSL)、07 (M10 デモ)
- Phase A (M5/M6/M6c、research 02) が完了していること

## 設計詳細

### 原則

- **すべての文は control pattern**: 値が control map の Pattern。音キー `:s` (将来
  :n/:note)、光キー = personality 属性 (:pan/:tilt/:dimmer/:strobe/:color/:gobo/:focus/
  :prism/:speed) + 配線キー `:target`
- **連続は存在しない**: DMX 出力は元々 40Hz の離散フレーム列 (実物の照明卓も離散
  スナップショット送出)。裸の Signal を構造源に使う場合は segment で離散化 (既定
  `SEGMENT_DEFAULT = 32`/cycle、明示 `segment(n)` 可)。スケジューラの連続バインド経路
  (`bind_continuous` / `sample_continuous`) は削除する
- **structure from left** (Tidal `#` / Strudel set): `sound("bd*4").pan(sine)` はキックの
  イベント時刻で sine をサンプルして control を添付。Signal を control として合流させる
  場合は `sample()` の係数 fast path 1 発なので segment 不要で軽い
- **バッファ 1 文 = 1 track** (`:stmt_0`, `:stmt_1`... 位置ベース)。トラック別 last-good /
  量子化差し替え / 空バッファ全停止は維持

### DSL 表面 (rootfs/lib/johakyu/control.rb 新規 + live.rb 改修)

```ruby
sound("bd*4")                            # Pattern of {s: "bd"}
sound("bd*4").color("<red blue>")        # 音イベント構造に色 control を添付 (音光一体の本命)
pan(sine.slow(8))                        # 自立した光: 自動 segment → {pan: v}
dmx(:s1).dimmer("1 0").color("<red blue>")  # 互換 sugar = dimmer("1 0").color(...).on(:s1)
pan("0.2 0.8").on(:all).spread(0.5)      # グループ配分: メンバー i を late(0.5*i/(n-1)) で複製 stack
```

- 光 control メソッド群は Pattern のメソッド + トップレベル構造源コンストラクタの両方
- `.on(target)` = `:target` control (record 時に Johakyu.dmx で検証)。省略時 :all
- `spread(amount)` は純粋なパターン変換: patch のメンバー展開 + `late` 複製の stack。
  配分規約は fixture.rb の Spread と同じ `amount * i / (n - 1)`
- 実装は Tidal の appLeft 相当 `Pattern#with_control(key, other)`: 左の各 Hap の
  whole.begin で右をサンプルし map をマージ。右が Signal なら `sample()` fast path
- 注意: `dmx(:s1).dimmer("1 0").color("<red blue>")` は structure-from-left になるため、
  color は dimmer のイベント時刻でサンプルされる (従来のトラック独立と意味が変わる)。
  独立構造が欲しければ 2 文に分ける

### Pattern 核追加 (pattern.rb / signal.rb)

- `Pattern#late(k)` / `#early(k)`: 既存 with_query_time / with_hap_time による巡回タイム
  シフト (spread に必要)
- `Signal` に `@time_offset` 係数を追加し、fast/slow/range/late/early を全て係数折込みに
  保つ: `sample(t) = off + scale * func(t*ts + toff)`、`fast(k) → ts*k`、`late(k) → toff - k*ts`
- `Pattern#with_control(key, pattern_or_value)` と control キー付与 (`fmap` で `{s:}` /
  `{pan:}` 化)

### ディスパッチャ (dsl.rb の Session 改修 + scheduler.rb 改修)

- staging 時に各 Hap の control map を音部分と光部分に分割 (1 回の query で両方作る。
  二重 query しない)
- 音部分 → **sample_clock 基準のサンプルオフセットに変換して C エンジンへ予約** (Phase A
  の予約 API)。tick ジッタから独立したサンプル精度になり、早撃ちハックは廃止
- 光部分 → `at_ms` に stage し、発火時に `:target` を fixture/group に解決して属性ごとに
  `fixture.set/raw` (現行 write_dmx の型規約: String 数値→正規化 Float、Integer→raw、
  Symbol/String→名前テーブル、Bool→全/零)
- Session の bind_dmx/dmx_seq/dmx_signal/SoundHandle/DmxTarget は削除し
  `Session#bind_statement(track, pattern)` に一本化。clock/scheduler/VOICES/gates/update/
  stop_sounds は不変。track 別 rescue (query エラー → last-good) は維持

### Live レコーダ (live.rb 書き直し)

- recording = `{ tempo:, latency:, statements: [] }`
- `play(pattern)` (トップレベル + Live#play): 追加して `Recorded` ハンドル (list, index)
  を返す。全 Pattern 変換メソッド + control メソッドを委譲し、呼ばれるたび `list[index]`
  を置換して self を返す (チェーンは自文のみに効く)
- `sound(p)` / `pan(p)` 等 / `dmx(target)` sugar はすべて play 経由。apply は statements を
  `:stmt_i` トラックへ bind し、余った旧トラックを remove

### ショー定義モジュール (新規 rootfs/data/johakyu/catalog.rb)

jo/ha/kyu はこのファイル限定の語彙。カタログは control pattern を返す:

- 序 (jo) = 基本型: 音のリズムパターン (heartbeat/kick2/kick4/backbeat/snare24/hats8/
  offbeat)、光の属性別の型 (home(pose)/pan_lr/tilt_ud/dimmer_wave/dimmer_beat/color_cycle/
  gobo_cycle/gobo_shake/strobe/prism/focus_sweep)
- 破 (ha) = 展開型: circle (pan=cos + tilt=sin を stack、center/radius/slow)、figure8
  (tilt を fast(2))、mirror (pan 波 + spread(0.5) = 逆方向)、chase (dimmer one-hot +
  spread)、color_beat (dimmer ビート + color)
- 急 (kyu) = 大技: strobe_burst / spin / finale (合成 stack)。本体は生 DSL での独自展開

```ruby
def jo(name, opts = {})
  play(JOHAKYU_JO.fetch(name) { raise ArgumentError, ... }.call(opts).on(opts[:on] || :all))
end   # ha / kyu 同様
```

app が起動時に catalog.rb を常駐 Sandbox で 1 回 eval する (トップレベル def は VM
グローバルに残るので Sandbox 再生成後も再ロード不要)。

### ベンチ (実装に組み込み、ゲートにする)

代表ショー (pan+tilt segment(32)×2 台 + kick4+hats8 + color_beat) で、ホスト = staging
1 チャンクの所要時間、実機 = tick 時間分布と late 数 (M8 と同じ計測方法)。

**最適化ラダー** (計測が悪化を示した段だけ適用):

1. SEGMENT_DEFAULT を下げる (32→16)
2. control map の Hash を単一 control は小配列にする (staging の Hash 割当削減)
3. 時間の固定小数点化 (1 cycle = 整数 tick、PPC = 2^5·3·5·7 = 3360、割り切れない分割は
   有理数フォールバック) で Fraction 割当を除去
4. サイクル単位の query キャッシュ

### UI / プリセット

- `Keyboard::F1-F3` 定数 (mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb)
- app johakyu.rb: F1/F2/F3 で `/data/johakyu/{jo,ha,kyu}.rb` をバッファへ読込 (eval せず
  F5 で適用)、catalog.rb 起動時ロード、コマンドバー更新
- プリセット 3 本: jo (tempo 90 + heartbeat/home + コメントの基本型) / ha (kick4+snare24+
  hats8 + circle(s1)+figure8(s2)+color_beat) / kyu (sound チェーン + circle 高速 +
  strobe_burst + finale コメント)

## 実施順序

### Phase A: 音エンジン先行 (M5/M6/M6c、research 02 に従う)

- A1. M5: pwm-audio の DMA 化 (Timer ISR → DMA ch2 + pacing timer、half-buffer 完了 IRQ
  `DMA_IRQ_0`、バッファ自律化)。クリックとピッチ誤差の解消を確認
- A2. M6: `PWMAudio.sample_clock` 公開 + サンプルオフセット予約 API
- A3. M6c: 拡張 audio_demo.rb で単体検証。C 変更は distclean 前提
- A4. WAV ワンショット再生は同 research の範囲だが後追い可 (M10 のゲートにしない)

### Phase B: all-pattern 化

- B1. pattern.rb/signal.rb: late/early + Signal time_offset + with_control (+ pattern_test)
- B2. control.rb + Session ディスパッチャ + scheduler 改修 (scheduler_test 改修)
- B3. live.rb 書き直し (statements + Recorded + sugar) → live_test 更新 (dmx チェーンは
  structure-from-left に期待値変更)
- B4. ホストベンチ + 実機ベンチ → 最適化ラダー適用判断 (ゲート)
- B5. catalog.rb + プリセット + F1-F3 + app 起動ロード (+ catalog_test: runner の stubs
  読込機構を流用)
- B6. ドキュメント更新 (research 07 の型システム節、masterplan の同期節を現状化)

## 受け入れ条件 (DoD)

- 既存テスト面 + 新規 (pattern late/early、with_control、dispatcher、catalog) が全て通る
- 代表ショーで実機 late tick なし、eval 中の音乱れなし (Phase A の成果と合わせて確認)
- `sound("bd*4").color("<red blue>")` (音イベント構造への光 control 添付) が実機で成立
- jo/ha/kyu プリセット 3 本で「静→展開→急」が成立 (research 07 の DoD と接続)

## 触るファイル

- Phase A: `mrbgems/picoruby-pwm-audio/` 一式 (research 02 の表どおり)
- Phase B 新規: `rootfs/lib/johakyu/control.rb`、`rootfs/data/johakyu/catalog.rb`、
  `rootfs/data/johakyu/{jo,ha,kyu}.rb`、`tests/catalog_test.rb`
- Phase B 調整: `rootfs/lib/johakyu/{pattern,signal,dsl,scheduler,live}.rb`、
  `rootfs/app/johakyu.rb`、`mrbgems/picoruby-keyboard-input/mrblib/keyboard.rb`、
  `tests/{pattern,scheduler,live}_test.rb`

## 次のハンドオフ先

- [research-johakyu-07-demo.md](research-johakyu-07-demo.md) (M10 の統合・演出・ランブック)
