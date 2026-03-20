# picorabbit 移植要件

## 調査結果サマリー

picorabbit は 13 スライドのプレゼンテーション + ミニゲームを含む独立ファームウェア。
640x240 RGB332 フレームバッファ直接描画で、Harucom の 320x240 とは解像度が異なる。
描画プリミティブ (draw_text, draw_line, draw_image) は Harucom の DVI::Graphics に不足しており追加が必要。
ビルドサイズは現在 1.1MB で、8MB の firmware 領域に十分な余裕がある。

## 詳細

### スライド構成

ファイル: `/home/harukasan/works/src/github.com/harukasan/picorabbit/mrblib/main_task.rb` (371行)

13 スライド構成:
- スライド 0-2: タイトル・カバー (draw_image で背景画像)
- スライド 3-11: テキストコンテンツ (draw_text でカラーテキスト、draw_image で進捗インジケーター)
- スライド 12: ミニゲーム (draw_rect で障害物、draw_image でキャラ回転、物理シミュレーション)

使用されている描画 API:
- `PicoRabbit::Draw.background(color)` -- memset で全面塗りつぶし
- `PicoRabbit::Draw.draw_rect(x, y, w, h, color)` -- 矩形描画
- `PicoRabbit::Draw.draw_text(text, x, y, color)` -- 8x8 フォントテキスト
- `PicoRabbit::Draw.draw_image(symbol, x, y, [angle])` -- 画像描画 (回転対応)
- `PicoRabbit::Draw.draw_line(x0, y0, x1, y1, color)` -- Bresenham ライン
- `PicoRabbit::Draw.commit()` -- フレームバッファスワップ

アニメーション:
- 回転ライン (`draw_line` + 三角関数)
- 色サイクリング (`f % 255`)
- スプライト回転 (`draw_image` の angle パラメータ)
- ゲーム物理 (重力、ジャンプ、障害物移動)

ナビゲーション: GPIO ボタン (RIGHT=次, LEFT=前)

### 描画プリミティブの詳細

ファイル: `/home/harukasan/works/src/github.com/harukasan/picorabbit/src/draw.c`

**draw_text**: font8x8_basic (8x8 ビットマップ) を1文字ずつビットブリット。2x 水平スケーリング適用。

**draw_image**: 生ピクセル配列をフレームバッファにコピー。ピクセルスケーリング対応。マスク (1bit/pixel 透過) 版と回転版もあり。

**draw_text_esc**: `\e[XX]` (XX は RGB332 の16進値) でテキスト内色変更。`\e[reset]` でデフォルト色に戻す。ANSI 標準とは異なる独自形式。

**draw_line**: Bresenham のライン描画。2x 水平スケーリング。

### 画像アセット

ディレクトリ: `/home/harukasan/works/src/github.com/harukasan/picorabbit/images/`

| 画像 | サイズ | 用途 |
|---|---|---|
| rubykaigi2025.png | 100 KB | カバースライド |
| background.png | 100 KB | タイトル背景 |
| kame.png | 440 B | 亀スプライト (透過あり) |
| usagi.png | 505 B | うさぎスプライト (透過あり) |

変換: `scripts/convert_image.rb` で PNG -> RGB332 + 1bit マスク -> C ヘッダー。
生成ヘッダー: `include/image.h` (911 KB、全画像データ埋め込み)。

### 解像度の違い

| | picorabbit | Harucom DVI::Graphics |
|---|---|---|
| 内部解像度 | 640x240 | 320x240 |
| 出力解像度 | 640x480 (2x 垂直) | 640x480 (2x 水平 + 2x 垂直) |
| ピクセル形式 | RGB332 | RGB332 |
| フレームバッファサイズ | 153.6 KB | 76.8 KB |
| 配置場所 | SRAM | SRAM |

picorabbit のスライドは 640x240 座標系で設計されている。Harucom の 320x240 にそのまま描画すると水平方向が半分になる。

対応方針の選択肢:
1. **座標を 1/2 スケール**: テキストやスプライトが小さくなるが簡単
2. **DVI::Graphics の解像度を 640x240 に変更**: SRAM 追加 77KB 必要。HSTX エンコーダの設定変更も必要
3. **picorabbit 側を 320x240 に再設計**: スライドレイアウトの修正が必要

### Harucom DVI::Graphics の現状

ファイル: `mrbgems/picoruby-dvi/ports/rp2350/dvi_output.c` (191行)

```c
static uint8_t framebuf[DVI_GRAPHICS_WIDTH * DVI_GRAPHICS_HEIGHT]; // 320x240 = 76.8KB
```

フレームバッファはメイン SRAM に静的確保。PSRAM ではない。
ダブルバッファリングは未実装 (picorabbit はダブルバッファ)。

不足している描画プリミティブ:
- `draw_text` (フォントレンダリング) -- 現在ピクセル単位の API のみ
- `draw_line` (ライン描画) -- なし
- `draw_image` (画像描画 + マスク + 回転) -- なし

### DVI モード切り替え

`DVI.set_mode(mode)` で VSync 同期でテキスト <-> グラフィックスをクリーンに切り替え可能。
HSTX の FIFO や DMA を停止する必要なし。フレーム境界で expand_shift レジスタを変更するだけ。

IRB (テキストモード) -> picorabbit (グラフィックスモード) -> IRB への復帰が可能。

### ビルドサイズ

| 項目 | サイズ |
|---|---|
| 現在のファームウェア (.bin) | 1.1 MB |
| UF2 ファイル | 2.2 MB |
| text セグメント | 1,108,648 bytes |
| bss セグメント | 190,532 bytes |
| firmware 領域上限 | 8 MB |
| 残り容量 | ~6.9 MB |

picorabbit の画像アセット (~200KB) と追加コードを含めても十分な余裕がある。

## マスタープランへの示唆

- DVI::Graphics に draw_text (8x8 フォント), draw_line (Bresenham), draw_image (マスク+回転) を C で追加
- 解像度差は要検討。最も現実的なのは picorabbit を 320x240 に再設計するか、座標スケーリング
- 画像アセットは `scripts/convert_image.rb` と同等の変換パイプラインで C ヘッダーに変換
- 入力は GPIO ボタンから USB キーボードに変更 (Ruby レベルの変更で対応可能)
- モード切り替え (テキスト <-> グラフィックス) は既存 API で対応可能
- ビルドサイズの制約は問題なし
