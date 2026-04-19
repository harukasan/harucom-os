# PSRAM (APS6404L-3SQR-SN)

The Harucom Board includes an AP Memory APS6404L-3SQR-SN (8 MB QSPI PSRAM).
It is used as the mruby VM heap, expanding the available memory from 256 KB
(on-chip SRAM) to 8 MB.

## Hardware configuration

| Item | Value |
|------|-------|
| IC | APS6404L-3SQR-SN |
| Capacity | 64 Mbit (8 MB) |
| Interface | SPI / QPI (SDR) |
| Max clock | 109 MHz (VDD=3.3V, Wrapped Burst) |
| CS pin | GPIO 0 (`PICO_RP2350_PSRAM_CS_PIN`) |
| Bus | QSPI (shared with flash: SCLK, SD0–SD3) |

The PSRAM CE# pin is connected to GPIO 0 with a 10 kΩ pull-up resistor to
keep it deselected by default. The QSPI data lines (SD0–SD3) and clock (SCLK)
are shared with the on-board flash (W25Q128JVS).

## RP2350 XIP subsystem and PSRAM

The RP2350 QMI (QSPI Memory Interface) supports two chip selects:

- **CS0** - Flash (dedicated QSPI_SS pin), memory window M0 (0x10000000–0x10FFFFFF)
- **CS1** - PSRAM (via GPIO), memory window M1 (0x11000000–0x117FFFFF)

A 16 kB XIP cache transparently covers both windows. The cache is write-back:
writes are held as dirty lines and flushed to PSRAM on eviction.

### Address aliases

The same physical address can be accessed through multiple aliases
(RP2350 datasheet §4.4.1):

| Base address | Description |
|---|---|
| `0x10000000` | Cached XIP access |
| `0x14000000` | Uncached (cache bypass) |
| `0x18000000` | Cache maintenance |
| `0x1C000000` | Uncached + untranslated (bypass ATRANS) |

The PSRAM cached address is `0x11000000`; its uncached alias is `0x15000000`.

## Initialization sequence

The implementation is in `src/psram.c`. Initialization proceeds in five steps.

### Step 1: Detect PSRAM (`get_psram_size`)

Uses QMI **direct mode** to send an SPI Read ID (0x9F) command, confirming the
PSRAM is present and determining its size. Direct mode suspends memory-mapped
(XIP) access and allows manual control of SPI transactions, so it works even
before ATRANS and M1 registers are configured.

To handle the case where the PSRAM is still in QPI mode after a warm reset,
Exit Quad Mode (0xF5) is sent in quad width first.

```
Exit QPI (0xF5, quad width) → Read ID (0x9F, SPI) → extract KGD/EID
```

The function is marked `__no_inline_not_in_flash_func` so it runs from RAM,
since flash XIP is paused while direct mode is active.

#### Flash access hazard in direct mode

When QMI direct mode is enabled, all XIP access (including flash) is
suspended.  Code running during direct mode must not reference any data
in flash.  In particular, aggregate initializers for local arrays
(e.g. `uint8_t cmds[] = {0x66, 0x99, 0x35}`) cause the compiler to emit
a template in `.rodata` (flash) and copy it to the stack, which crashes.
Use individual assignments instead so the values are encoded as immediate
operands in RAM-resident instructions.

### Step 2: Configure CS1 (bootrom flash_devinfo API)

The bootrom is informed about the CS1 device via its runtime API. The
QMI M0 (flash CS0) registers are saved around the bootrom calls to
preserve the fast QSPI XIP mode that boot2 configured at startup:

```c
flash_devinfo_set_cs_gpio(1, PICO_RP2350_PSRAM_CS_PIN);  // GPIO 0
flash_devinfo_set_cs_size(1, FLASH_DEVINFO_SIZE_8M);      // 8 MB

// Save M0 (flash CS0) before the bootrom overwrites it
uint32_t m0_timing = qmi_hw->m[0].timing;
uint32_t m0_rfmt   = qmi_hw->m[0].rfmt;
uint32_t m0_rcmd   = qmi_hw->m[0].rcmd;

rom_connect_internal_flash();
rom_flash_exit_xip();
rom_flash_enter_cmd_xip();

// Restore fast QSPI XIP mode for flash CS0
qmi_hw->m[0].timing = m0_timing;
qmi_hw->m[0].rfmt   = m0_rfmt;
qmi_hw->m[0].rcmd   = m0_rcmd;
```

This API is the runtime equivalent of programming the OTP FLASH_DEVINFO
register. It causes the bootrom to configure:

- **ATRANS registers** - address translation from XIP address space to CS1
- **GPIO pads** - output configuration for the CS1 pin

#### Why manual ATRANS writes alone do not work

Writing the QMI ATRANS registers directly is **not sufficient** for
memory-mapped CS1 access. The bootrom must set up additional internal state
(pad configuration, etc.) that is only applied through
`rom_connect_internal_flash()`.

This behavior is discussed in the pico-sdk GitHub issue:
https://github.com/raspberrypi/pico-sdk/issues/2205

#### Preserving fast QSPI XIP mode for flash

`rom_flash_exit_xip()` and `rom_flash_enter_cmd_xip()` reprogram the QMI
M0 (flash CS0) registers for slow single-SPI XIP access. Without
restoring them, code execution from flash runs 2-6x slower after
`psram_init()` returns. The VM's bytecode interpreter runs from flash
XIP, so this affects all Ruby code execution.

`pico-sdk`'s `flash_range_erase()` / `flash_range_program()` normally
restore fast QSPI mode via an internal `flash_enable_xip_via_boot2()`
call, so this slowdown only manifests on boot paths that perform no
flash writes after PSRAM init. We save M0 (`timing`, `rfmt`, `rcmd`)
before the bootrom calls and restore them immediately after. This is
the same save/restore pattern pico-sdk uses for CS1 preservation in
`flash_rp2350_save_qmi_cs1`.

### Step 3: Enter QPI mode

The following SPI commands are sent to the PSRAM via QMI direct mode:

| Command | Code | Description |
|---|---|---|
| Reset Enable | 0x66 | Prepare for reset (must immediately precede 0x99) |
| Reset | 0x99 | Software reset, returns device to SPI standby mode |
| Enter Quad Mode | 0x35 | Switch to QPI mode (only valid in SPI mode) |

After reset the device is in SPI mode (datasheet §8.4). Enter Quad Mode
switches it to QPI for higher throughput.

### Step 4: Configure QMI M1 registers

The QMI memory window 1 registers are programmed for QPI read/write access.

**Read - Fast Quad Read (0xEB):**

```
[CMD 0xEB: 2 clk] [24-bit ADDR: 6 clk] [6 WAIT: 6 clk] [DATA...]
      quad              quad                  quad            quad
```

- All phases (command, address, dummy, data) use 4 lines (quad)
- 6 wait cycles = 24 dummy bits (`DUMMY_LEN_VALUE_24`)
- Max 133 MHz

**Write - Quad Write (0x38):**

```
[CMD 0x38: 2 clk] [24-bit ADDR: 6 clk] [DATA...]
      quad              quad               quad
```

- No dummy cycles
- Max 133 MHz

**Timing (`set_psram_timing`):**

Clock divider, MAX_SELECT, and MIN_DESELECT are computed dynamically from
`clk_sys`. Call `set_psram_timing()` again after changing the system clock
(e.g. overclocking).

| Parameter | Value | Description |
|---|---|---|
| CLKDIV | ceil(sys_clk / 109 MHz) | Limit SCK to ≤ 109 MHz |
| MAX_SELECT | tCEM / (64 × sys_clk period) | Max CS# low time (8 µs) |
| MIN_DESELECT | ceil(tCPH / sys_clk period) | Min CS# high time (50 ns) |
| PAGEBREAK | 1024 bytes | Break bursts at 1 kB page boundary |
| RXDELAY | ceil(4 ns / half sys_clk period) | Read data sample delay (≥ tCKQS) |

RXDELAY is computed dynamically to maintain approximately 4 ns of sample
delay regardless of sys_clk frequency. At 125 MHz this yields RXDELAY=1;
at 372 MHz (DVI overclock) this yields RXDELAY=3.

### Step 5: Enable XIP writes

```c
xip_ctrl_hw->ctrl |= XIP_CTRL_WRITABLE_M1_BITS;
```

XIP memory window 1 is **read-only by default** (RP2350 datasheet §4.4.5,
XIP_CTRL.WRITABLE_M1). Without this bit set, writes to PSRAM are silently
dropped and the XIP cache may return stale data.

## Initialization order

[init_rootfs](../src/init_rootfs.c) runs before `psram_init` in
[src/main.c](../src/main.c). `pico-sdk`'s `flash_range_program` /
`flash_range_erase` send an XIP exit sequence to every chip select
advertised via `flash_devinfo`, which puts an already-initialized PSRAM
back into serial command state and clobbers QMI M1 write registers (see
`flash_rp2350_restore_qmi_cs1` "Case 2" in
[pico-sdk flash.c](../lib/pico-sdk/src/rp2_common/hardware_flash/flash.c)).
Running `init_rootfs` first keeps CS1 unadvertised during the deployment
flash writes, so the ROM does not disturb the PSRAM interface that
`psram_init` configures immediately afterwards. Runtime flash writes
(for example when Ruby code writes files through LittleFS) re-enter that
hazard and would need separate handling.

## Permanent configuration via OTP

As an alternative to the runtime API, OTP can be programmed so the bootrom
automatically configures CS1 on every boot. **OTP writes are irreversible.**

| OTP field | Value | Description |
|---|---|---|
| `FLASH_DEVINFO.CS1_GPIO` | 0 | GPIO 0 |
| `FLASH_DEVINFO.CS1_SIZE` | 0xB | 8 MB |
| `FLASH_DEVINFO.CS0_SIZE` | 0xC | 16 MB (Flash) |
| `FLASH_DEVINFO.D8H_ERASE_SUPPORTED` | 1 | 64 KB block erase supported |
| `BOOT_FLAGS0.FLASH_DEVINFO_ENABLE` | 1 | Enable FLASH_DEVINFO |

picotool commands:

```sh
picotool otp set FLASH_DEVINFO 0xbc80
picotool otp set BOOT_FLAGS0 0x20
```

## References

- [APS6404L-3SQR datasheet (AP Memory)](https://www.apmemory.com/en/downloadFiles/032411212009597427)
- [RP2350 datasheet §4.4 "External flash and PSRAM (XIP)"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [pico-sdk issue #2205 - runtime CS1 configuration without OTP](https://github.com/raspberrypi/pico-sdk/issues/2205)
- [SparkFun sparkfun-pico library (sfe_psram.c)](https://github.com/sparkfun/sparkfun-pico)
