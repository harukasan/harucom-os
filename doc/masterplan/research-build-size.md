# ビルドサイズとメモリ予算

## 調査結果サマリー

現在のファームウェアは 1.1MB で、8MB の firmware 領域に 6.9MB の余裕がある。
DVI::Graphics フレームバッファは SRAM に 76.8KB 確保。
mrbgem 追加によるサイズ増加は管理可能な範囲。

## 詳細

### 現在のビルドサイズ

| 項目 | サイズ |
|---|---|
| harucom_os.elf | 2.3 MB |
| harucom_os.bin | 1.1 MB (1,108,648 bytes text) |
| harucom_os.uf2 | 2.2 MB |
| bss (SRAM 使用) | 190,532 bytes |
| data | 2,048 bytes |

### Flash レイアウト

```
0x00000000 - 0x007FFFFF (8 MB): ファームウェア領域
0x00800000 - 0x00FFFFFF (8 MB): FAT ファイルシステム
```

firmware 領域の残り: 8 MB - 1.1 MB = **6.9 MB**

### SRAM 使用量

RP2350 メイン SRAM: 520 KB

主要な使用先:
- テキスト VRAM: ~15.7 KB (106x37x4 bytes)
- グリフキャッシュ (narrow + wide): ~32.6 KB
- ラインバッファ: ~5.2 KB
- グラフィックスフレームバッファ: 76.8 KB (320x240)
- Core 0 スタック (BSS): 32 KB
- Core 1 スタック: 4 KB
- Core 1 ベクタテーブル: 272 bytes
- stdin ringbuffer: ~260 bytes
- BSS その他: ~24 KB (概算)

合計 BSS: 190,532 bytes (~186 KB)
SRAM 残り: ~334 KB

### PSRAM 使用量

APS6404L 8 MB 全体を mruby ヒープとして使用。
XIP マッピング (キャッシュ経由): 0x11000000 - 0x117FFFFF

### mrbgem 追加による影響の見積もり

追加予定の mrbgem:
- picoruby-sandbox: C + Ruby コード、タスク管理ロジック (~10-20 KB text)
- picoruby-machine: ハードウェア制御ポート (~5-10 KB text)
- picoruby-env: 環境変数管理 (~2-5 KB text)

概算サイズ増加: 20-40 KB (firmware text)

picorabbit 画像アセット追加時: ~200 KB (RGB332 画像データ、flash に配置)

合計でも firmware 領域の余裕 (6.9 MB) に対して十分に小さい。

### DVI::Graphics フレームバッファ

ファイル: `mrbgems/picoruby-dvi/ports/rp2350/dvi_output.c` (191行)

```c
static uint8_t framebuf[DVI_GRAPHICS_WIDTH * DVI_GRAPHICS_HEIGHT]; // 76,800 bytes
```

メイン SRAM に静的確保。PSRAM ではない。
ダブルバッファリング未実装 (シングルバッファ)。

もし 640x240 に拡大する場合: 追加 76.8 KB で合計 153.6 KB。SRAM 残量 (~334 KB) から確保可能だが、他の用途を圧迫する。

## マスタープランへの示唆

- ファームウェアサイズの制約は問題なし (6.9 MB の余裕)
- SRAM はやや tight だが現状の 320x240 フレームバッファなら問題なし
- picorabbit の画像アセット (~200 KB) は flash 直接配置で対応
- mrbgem 追加のサイズ影響は軽微
