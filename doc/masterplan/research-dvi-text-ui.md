# DVI テキスト VRAM による UI 構築

## 調査結果サマリー

DVI テキスト VRAM は 106x37 セルの配列で、C から直接アクセス可能。
スクロールは VRAM 上の memmove で実現可能だが、専用関数がまだない。
カーソル描画はセルの属性バイト (fg/bg) を反転トグルすることで実現できる。
Ruby API には scroll, clear_line, 属性読み取りが不足しており、C での追加が必要。

## 詳細

### テキスト VRAM データ構造

ファイル: `mrbgems/picoruby-dvi/include/dvi.h` (24-28行)

```c
typedef struct {
    uint16_t ch;   // 文字コード (ASCII or 線形 JIS インデックス)
    uint8_t attr;  // bits 7-4: 前景パレット, bits 3-0: 背景パレット
    uint8_t flags; // DVI_CELL_FLAG_WIDE_L, WIDE_R, BOLD
} dvi_text_cell_t;
```

- 106列 x 37行 = 3,922 セル (15.7 KB)
- 行優先配列: `text_vram[row * 106 + col]`
- `static dvi_text_cell_t text_vram[...]` -- メイン SRAM に静的確保

### 既存 C API

| 関数 | 説明 |
|---|---|
| `dvi_get_text_vram()` | VRAM ポインタ取得 (直接アクセス用) |
| `dvi_text_get_cols()` / `get_rows()` | 106 / 37 |
| `dvi_text_put_char(col, row, ch, attr)` | 半角文字配置 |
| `dvi_text_put_char_bold(col, row, ch, attr)` | 太字文字配置 |
| `dvi_text_put_wide_char(col, row, ch, attr)` | 全角文字配置 |
| `dvi_text_put_string(col, row, str, attr)` | UTF-8 文字列配置 |
| `dvi_text_clear(attr)` | 全画面クリア |
| `dvi_text_clear_line(row, attr)` | 1行クリア |

### 既存 Ruby API

| メソッド | 説明 |
|---|---|
| `DVI::Text.put_char(col, row, ch, attr)` | 半角文字配置 |
| `DVI::Text.put_string(col, row, str, attr)` | UTF-8 文字列配置 |
| `DVI::Text.clear(attr)` | 全画面クリア |
| `DVI::Text::COLS` / `ROWS` | 106 / 37 |

### 不足している操作と追加方針

**1. スクロール**

VRAM は連続メモリなので memmove で実現可能:
```c
void dvi_text_scroll_up(int lines, uint8_t fill_attr) {
    dvi_text_cell_t *vram = dvi_get_text_vram();
    int cols = DVI_TEXT_MAX_COLS;
    int rows = DVI_TEXT_MAX_ROWS;
    memmove(&vram[0], &vram[lines * cols], (rows - lines) * cols * sizeof(dvi_text_cell_t));
    // 末尾行をクリア
    for (int r = rows - lines; r < rows; r++)
        dvi_text_clear_line(r, fill_attr);
}
```

Ruby API に `DVI::Text.scroll_up(lines, attr)` として公開する。

**2. 部分行クリア**

`dvi_text_clear_line` は行全体のクリアのみ。部分クリアが必要:
```c
void dvi_text_clear_range(int col, int row, int width, uint8_t attr);
```

Ruby API に `DVI::Text.clear_range(col, row, width, attr)` として公開する。

**3. セル属性の読み取り (カーソル描画用)**

VRAM から直接読める (`dvi_get_text_vram()`) が Ruby からは不可。
```c
uint8_t dvi_text_get_attr(int col, int row);
void dvi_text_set_attr(int col, int row, uint8_t attr);
```

カーソル描画: 属性の fg/bg を反転してタイマーでトグル。

**4. DVI::Text.clear_line の Ruby 公開**

C には `dvi_text_clear_line()` があるが Ruby バインディングがない。追加する。

### カーソル描画方法

属性バイトの fg (上位4bit) と bg (下位4bit) をスワップすることで反転表示:
```c
uint8_t attr = vram[row * cols + col].attr;
uint8_t inverted = ((attr & 0x0F) << 4) | ((attr & 0xF0) >> 4);
```

Core 0 の repeating_timer (500ms 間隔) でトグルすればカーソルブリンクが実現できる。
または Ruby 側でフレーム単位 (30フレームごと等) にトグルする方法もある。

### VRAM 直接アクセスのスレッドセーフティ

- Core 1 (DVI レンダラー) は VRAM を読み取り専用で使用
- Core 0 (mruby) が VRAM を書き込む
- 書き込み中のセルが読まれてもティアリングは1セル単位 (4バイト) なので視覚的影響は軽微
- 特別なロック機構は不要

## マスタープランへの示唆

- DVI::Text に scroll_up, clear_range, clear_line, get_attr, set_attr の C API + Ruby バインディング追加が必要
- これが IRB とエディタ両方の画面描画基盤になる
- カーソルは属性反転で実装 (専用フラグ不要)
- 追加 API は比較的小規模 (各数行の C コード)
