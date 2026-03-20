# USB キーボード入力レイヤー

## 調査結果サマリー

TinyUSB に HID キーコード -> ASCII 変換テーブル (`HID_KEYCODE_TO_ASCII`) が既に存在する。
HID コールバックは Core 0 のコンテキストで実行され、hal_stdin_push() への統合はスレッドセーフ。
C レベルでの変換実装を推奨。キーリピートもソフトウェア実装が必要。

## 詳細

### 現在の USB キーボード実装

ファイル: `mrbgems/picoruby-usb-host/ports/rp2350/usb_host.c`

HID レポート構造:
```c
typedef struct {
    uint8_t modifier;    // Ctrl, Shift, Alt, GUI (左右各4bit)
    uint8_t reserved;
    uint8_t keycode[6];  // 同時押し最大6キー (0 = 未押下)
} hid_keyboard_report_t;
```

状態管理:
- `keyboard_modifier_state` -- 修飾キーバイト
- `keyboard_keycodes_state[6]` -- 押下中キーコード配列
- `tuh_hid_report_received_cb()` でレポート受信のたびに更新

現在の処理: レポートのコピーのみ。文字変換なし。Ruby 側でポーリング (`USB::Host.keyboard_keycodes`) して使う設計。

### TinyUSB の HID 変換テーブル

ファイル: `lib/pico-sdk/lib/tinyusb/src/class/hid/hid.h` (1222-1329行)

```c
#define HID_KEYCODE_TO_ASCII \
    {0, 0},         /* 0x00 */ \
    ...
    {'a', 'A'},     /* 0x04 HID_KEY_A */ \
    {'b', 'B'},     /* 0x05 HID_KEY_B */ \
    ...
    {'1', '!'},     /* 0x1E */ \
    {'2', '@'},     /* 0x1F */ \
    ...
    {'\r', '\r'},   /* 0x28 Enter */ \
    {'\x1b', '\x1b'}, /* 0x29 Escape */ \
    {'\b', '\b'},   /* 0x2A Backspace */ \
    {'\t', '\t'},   /* 0x2B Tab */ \
    {' ', ' '},     /* 0x2C Space */ \
    ...
```

128エントリ x 2バイト (unshifted, shifted)。US キーボードレイアウト。

使い方:
```c
static const uint8_t keycode2ascii[128][2] = { HID_KEYCODE_TO_ASCII };
bool is_shift = modifier & (KEYBOARD_MODIFIER_LEFTSHIFT | KEYBOARD_MODIFIER_RIGHTSHIFT);
char ch = keycode2ascii[keycode][is_shift ? 1 : 0];
```

### キー処理の実装方針

C レベルで HID コールバック内に変換処理を追加し、hal_stdin_push() で ringbuffer に投入する:

```c
void keyboard_process_report(uint8_t modifier, const uint8_t keycodes[6]) {
    static uint8_t prev_keycodes[6] = {0};
    bool is_shift = modifier & (KEYBOARD_MODIFIER_LEFTSHIFT | KEYBOARD_MODIFIER_RIGHTSHIFT);
    bool is_ctrl = modifier & (KEYBOARD_MODIFIER_LEFTCTRL | KEYBOARD_MODIFIER_RIGHTCTRL);

    for (int i = 0; i < 6; i++) {
        uint8_t kc = keycodes[i];
        if (kc == 0) continue;
        if (find_in_prev(prev_keycodes, kc)) continue;  // 既に押下中

        // 特殊キー -> エスケープシーケンス
        if (kc == HID_KEY_ARROW_UP)    { push_string("\x1b[A"); continue; }
        if (kc == HID_KEY_ARROW_DOWN)  { push_string("\x1b[B"); continue; }
        if (kc == HID_KEY_ARROW_LEFT)  { push_string("\x1b[D"); continue; }
        if (kc == HID_KEY_ARROW_RIGHT) { push_string("\x1b[C"); continue; }
        // ... Home, End, Delete 等

        // 通常キー
        char ch = keycode2ascii[kc][is_shift ? 1 : 0];
        if (ch == 0) continue;
        if (is_ctrl && ch >= 'a' && ch <= 'z') ch = ch - 'a' + 1;  // Ctrl-A=1, Ctrl-C=3
        hal_stdin_push(ch);
    }
    memcpy(prev_keycodes, keycodes, 6);
}
```

### スレッドセーフティ

- `tuh_hid_report_received_cb()` は `tuh_task()` 内から呼ばれる
- `tuh_task()` は Core 0 で実行される (PIO-USB SOF タイマー IRQ の延長)
- `hal_stdin_push()` は RingBuffer に push (Core 0 で完結)
- Core 1 は DVI 専用で stdin にアクセスしない
- 割り込みコンテキストの考慮: PIO-USB IRQ (priority 0x00) から呼ばれる可能性あり。hal_stdin_push() 内で割り込み禁止は不要 (単一プロデューサー)

### キーリピート

USB HID boot protocol はキー状態のスナップショットを送るだけで、リピートイベントは生成しない。ソフトウェア実装が必要:

- 押下開始タイムスタンプを記録
- 初期ディレイ (400ms) 後、リピート間隔 (50ms) で文字を再投入
- `timer_hw->timerawl` でマイクロ秒タイムスタンプを取得
- `keyboard_process_report()` 内で前回レポートと比較し、継続押下を検出

### Ruby 実装 vs C 実装

| 項目 | Ruby 実装 | C 実装 |
|---|---|---|
| レスポンス | Task.pass 依存 (~1ms) | HID コールバック直接 |
| 実装の柔軟性 | 高い (キーマップ変更容易) | 低い (再ビルド必要) |
| キーリピート | Task ループで実装 | タイマーで実装 |
| hal_stdin_push 統合 | 不可 (Ruby からは別経路) | 直接統合 |

推奨: **C 実装**。hal_stdin_push() に直接統合することで、Sandbox の wait() 中でもキー入力が処理される。

## マスタープランへの示唆

- `src/keyboard.c` を新規作成し、HID キーコード変換 + キーリピートを実装
- TinyUSB の `HID_KEYCODE_TO_ASCII` テーブルをそのまま利用
- usb_host.c の HID コールバックから `keyboard_process_report()` を呼び出す
- 矢印キー等の特殊キーはエスケープシーケンスとして push
- IRB/エディタの入力は hal_getchar() 経由で統一的に受け取れる
