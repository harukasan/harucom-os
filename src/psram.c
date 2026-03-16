/*
 * PSRAM driver for APS6404L-3SQR-SN (8 MB QSPI PSRAM) on RP2350.
 *
 * The APS6404L is connected to QMI chip select 1 (CS1) via a GPIO pin
 * defined by PICO_RP2350_PSRAM_CS_PIN in the board header.  It shares
 * the QSPI bus (SCLK, SD0–SD3) with the flash on CS0.
 *
 * Initialization sequence
 * -----------------------
 *  1. Detect — Read the PSRAM device ID via QMI direct mode to confirm
 *     the chip is present and determine its size.
 *  2. Configure CS1 — Use the bootrom's flash_devinfo runtime API
 *     (flash_devinfo_set_cs_gpio / flash_devinfo_set_cs_size) to tell
 *     the bootrom about the CS1 device, then call rom_connect_internal_flash()
 *     so the bootrom sets up ATRANS address translation and GPIO pads.
 *     Writing ATRANS registers manually is NOT sufficient; the bootrom must
 *     configure additional internal state for memory-mapped CS1 access to
 *     work.  See: https://github.com/raspberrypi/pico-sdk/issues/2205
 *  3. Enter QPI — Send Reset Enable (0x66), Reset (0x99), and Enter Quad
 *     Mode (0x35) to the PSRAM via QMI direct mode.
 *  4. Configure QMI M1 — Set timing, read/write format, and command
 *     registers for QPI access (0xEB read, 0x38 write).
 *  5. Enable writes — Set XIP_CTRL.WRITABLE_M1 so the XIP subsystem
 *     permits writes to memory window 1 (default is read-only).
 *
 * Address mapping
 * ---------------
 * After initialization the PSRAM is memory-mapped at 0x11000000 (cached)
 * through the XIP subsystem.  The 16 kB XIP write-back cache covers both
 * CS0 (flash) and CS1 (PSRAM).
 *
 * Alternatives to the runtime API
 * --------------------------------
 * The same CS1 configuration can be made permanent by programming OTP:
 *   - FLASH_DEVINFO.CS1_GPIO = <pin>
 *   - FLASH_DEVINFO.CS1_SIZE = 0xB (8 MB)
 *   - BOOT_FLAGS0.FLASH_DEVINFO_ENABLE = 1
 * This causes the bootrom to configure CS1 automatically on every boot,
 * eliminating the need for the runtime API calls above.
 *
 * References
 * ----------
 *  - APS6404L-3SQR datasheet (AP Memory)
 *  - RP2350 datasheet §4.4 "External flash and PSRAM (XIP)"
 *  - pico-sdk issue #2205 — runtime CS1 configuration without OTP
 *  - SparkFun sparkfun-pico library (sfe_psram.c, MIT license)
 */

#include "psram.h"

#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "hardware/clocks.h"
#include "hardware/flash.h"
#include "hardware/structs/qmi.h"
#include "hardware/structs/xip_ctrl.h"
#include "hardware/regs/addressmap.h"
#include "hardware/gpio.h"
#include "hardware/sync.h"

#define PSRAM_SIZE (8 * 1024 * 1024)

/*
 * APS6404L SPI/QPI command set (see datasheet §8.5, Table).
 *
 * The device powers up in SPI mode.  After issuing Enter Quad Mode
 * (0x35), all subsequent commands use QPI (4-bit) transfers.  Exit
 * Quad Mode (0xF5) returns to SPI and is the only command that must
 * be sent in quad width while the device is in QPI mode.
 */
#define CMD_RESET_ENABLE 0x66  /* Reset Enable (SPI & QPI) */
#define CMD_RESET        0x99  /* Reset (SPI & QPI) — must follow 0x66 immediately */
#define CMD_QUAD_ENABLE  0x35  /* Enter Quad Mode (SPI only) */
#define CMD_QUAD_END     0xF5  /* Exit Quad Mode (QPI only) */
#define CMD_READ_ID      0x9F  /* Read ID (SPI only) */
#define CMD_READ_QUAD    0xEB  /* Fast Quad Read: cmd + 24-bit addr + 6 wait cycles + data */
#define CMD_WRITE_QUAD   0x38  /* Quad Write: cmd + 24-bit addr + data (no wait cycles) */
#define CMD_NOOP         0xFF

/* Known Good Die identifier (datasheet §10.4, Table 4) */
#define PSRAM_KGD 0x5D

/*
 * Timing constants in femtoseconds (1 fs = 1e-15 s) for integer math.
 * From the APS6404L datasheet §14.6 "AC Characteristics":
 *   tCEM  (max CS# low)  = 8 µs   → 8e6 ns → 8e15 fs / 64 = 125e6 fs
 *   tCPH  (min CS# high) = 50 ns  → 50e6 fs
 *   fmax  (VDD = 3.3 V)  = 109 MHz (Wrapped Burst)
 */
#define SEC_TO_FS             1000000000000000ll
#define PSRAM_MAX_SELECT_FS   125000000  /* tCEM / 64 (QMI MAX_SELECT unit) */
#define PSRAM_MIN_DESELECT_FS 50000000   /* tCPH */
#define PSRAM_MAX_SCK_HZ      109000000  /* max SCK at 3.3 V */

/* ------------------------------------------------------------------ */

/*
 * Detect the PSRAM via a direct-mode SPI Read ID (0x9F) transaction.
 *
 * Direct mode lets us talk to the PSRAM without memory-mapped access,
 * so this function is safe even when ATRANS / M1 are not yet configured.
 * It also sends Exit QPI (0xF5) first in case the device is still in
 * QPI mode from a previous (warm) boot.
 *
 * Returns the detected size in bytes, or 0 if no PSRAM is found.
 *
 * Must run from RAM (__no_inline_not_in_flash_func) because QMI direct
 * mode pauses all XIP (flash) access.
 */
static size_t __no_inline_not_in_flash_func(get_psram_size)(void)
{
    size_t psram_size = 0;
    uint32_t save = save_and_disable_interrupts();

    /* Enter direct mode with a conservative clock (sys_clk / 30 ≈ 5 MHz) */
    qmi_hw->direct_csr = 30 << QMI_DIRECT_CSR_CLKDIV_LSB | QMI_DIRECT_CSR_EN_BITS;
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) {}

    /* Exit QPI mode (0xF5 in quad width) — harmless if already in SPI */
    qmi_hw->direct_csr |= QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
    qmi_hw->direct_tx = QMI_DIRECT_TX_OE_BITS
                       | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB)
                       | CMD_QUAD_END;
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) {}
    (void)qmi_hw->direct_rx;
    qmi_hw->direct_csr &= ~QMI_DIRECT_CSR_ASSERT_CS1N_BITS;

    /*
     * SPI Read ID (0x9F): 1 cmd byte + 3 address bytes + 2 ID bytes = 7
     * clocked bytes total.  Byte 5 = KGD, byte 6 = EID.
     */
    qmi_hw->direct_csr |= QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
    uint8_t kgd = 0, eid = 0;
    for (int i = 0; i < 7; i++) {
        qmi_hw->direct_tx = (i == 0) ? CMD_READ_ID : CMD_NOOP;
        while ((qmi_hw->direct_csr & QMI_DIRECT_CSR_TXEMPTY_BITS) == 0) {}
        while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) {}
        if (i == 5)      kgd = (uint8_t)qmi_hw->direct_rx;
        else if (i == 6) eid = (uint8_t)qmi_hw->direct_rx;
        else             (void)qmi_hw->direct_rx;
    }
    qmi_hw->direct_csr &= ~QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
    qmi_hw->direct_csr &= ~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS);

    restore_interrupts(save);

    printf("PSRAM ID: KGD=0x%02x EID=0x%02x\n", kgd, eid);

    if (kgd == PSRAM_KGD) {
        /* Decode size from EID[7:5] (datasheet §10.4) */
        psram_size = 1024 * 1024;
        uint8_t size_id = eid >> 5;
        if (eid == 0x26 || size_id == 2)
            psram_size *= 8;
        else if (size_id == 0)
            psram_size *= 2;
        else if (size_id == 1)
            psram_size *= 4;
    }
    return psram_size;
}

/*
 * Compute and apply M1 timing parameters based on the current sys_clk.
 *
 * Call this again after overclocking to keep PSRAM within spec.
 */
static void __no_inline_not_in_flash_func(set_psram_timing)(void)
{
    uint32_t sys_hz = clock_get_hz(clk_sys);
    uint8_t clkdiv = (sys_hz + PSRAM_MAX_SCK_HZ - 1) / PSRAM_MAX_SCK_HZ;
    uint32_t fs_per_cycle = SEC_TO_FS / sys_hz;
    uint8_t max_select = PSRAM_MAX_SELECT_FS / fs_per_cycle;
    uint8_t min_deselect = (PSRAM_MIN_DESELECT_FS + fs_per_cycle - 1) / fs_per_cycle;

    uint32_t save = save_and_disable_interrupts();
    qmi_hw->m[1].timing =
          (2u << QMI_M1_TIMING_PAGEBREAK_LSB)      /* 1024-byte page boundary */
        | (3u << QMI_M1_TIMING_SELECT_HOLD_LSB)    /* 3 extra hold cycles */
        | (1u << QMI_M1_TIMING_COOLDOWN_LSB)       /* sequential burst reuse */
        | (1u << QMI_M1_TIMING_RXDELAY_LSB)        /* ½ sys_clk sample delay */
        | (max_select << QMI_M1_TIMING_MAX_SELECT_LSB)
        | (min_deselect << QMI_M1_TIMING_MIN_DESELECT_LSB)
        | (clkdiv << QMI_M1_TIMING_CLKDIV_LSB);
    restore_interrupts(save);
}

/*
 * Full PSRAM setup: bootrom CS1 config → QPI mode → M1 registers.
 *
 * After this function returns, the PSRAM is accessible as memory-mapped
 * read/write storage at XIP_BASE + 16 MB (0x11000000).
 */
static void __no_inline_not_in_flash_func(setup_psram)(void)
{
    /*
     * Inform the bootrom about CS1 via the runtime flash_devinfo API.
     *
     * This is equivalent to programming OTP FLASH_DEVINFO but does not
     * require burning any fuses.  After these calls, rom_connect_internal_flash()
     * will configure ATRANS and GPIO pads for CS1.
     *
     * IMPORTANT: Manually writing QMI ATRANS registers is NOT enough.
     * The bootrom must set up additional internal state (pad config, etc.)
     * for memory-mapped CS1 access to work.
     */
    flash_devinfo_set_cs_gpio(1, PICO_RP2350_PSRAM_CS_PIN);
    flash_devinfo_set_cs_size(1, FLASH_DEVINFO_SIZE_8M);

    uint32_t save = save_and_disable_interrupts();

    /* Apply CS1 configuration through the bootrom */
    rom_connect_internal_flash();
    rom_flash_exit_xip();
    rom_flash_enter_cmd_xip();

    /*
     * Enter QPI mode on the PSRAM via direct mode.
     *
     * After reset the device is in SPI mode (datasheet §8.4).
     * We send Reset Enable + Reset to ensure a clean state, then
     * Enter Quad Mode to switch to QPI for higher throughput.
     */
    qmi_hw->direct_csr = 30 << QMI_DIRECT_CSR_CLKDIV_LSB | QMI_DIRECT_CSR_EN_BITS;
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) {}

    const uint8_t cmds[] = { CMD_RESET_ENABLE, CMD_RESET, CMD_QUAD_ENABLE };
    for (int i = 0; i < 3; i++) {
        qmi_hw->direct_csr |= QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
        qmi_hw->direct_tx = cmds[i];
        while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) {}
        qmi_hw->direct_csr &= ~QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
        for (volatile int j = 0; j < 20; j++) { __asm volatile("nop"); }
        (void)qmi_hw->direct_rx;
    }

    qmi_hw->direct_csr &= ~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS);
    restore_interrupts(save);

    set_psram_timing();

    save = save_and_disable_interrupts();

    /*
     * QMI M1 read format — QPI Fast Quad Read (0xEB):
     *   All phases (prefix, addr, dummy, data) on 4 lines.
     *   24-bit address, 6 wait cycles = 24 dummy bits.
     *   Max frequency 133 MHz (datasheet §8.5).
     */
    qmi_hw->m[1].rfmt =
          (QMI_M1_RFMT_PREFIX_WIDTH_VALUE_Q << QMI_M1_RFMT_PREFIX_WIDTH_LSB)
        | (QMI_M1_RFMT_ADDR_WIDTH_VALUE_Q << QMI_M1_RFMT_ADDR_WIDTH_LSB)
        | (QMI_M1_RFMT_SUFFIX_WIDTH_VALUE_Q << QMI_M1_RFMT_SUFFIX_WIDTH_LSB)
        | (QMI_M1_RFMT_DUMMY_WIDTH_VALUE_Q << QMI_M1_RFMT_DUMMY_WIDTH_LSB)
        | (QMI_M1_RFMT_DUMMY_LEN_VALUE_24 << QMI_M1_RFMT_DUMMY_LEN_LSB)
        | (QMI_M1_RFMT_DATA_WIDTH_VALUE_Q << QMI_M1_RFMT_DATA_WIDTH_LSB)
        | (QMI_M1_RFMT_PREFIX_LEN_VALUE_8 << QMI_M1_RFMT_PREFIX_LEN_LSB)
        | (QMI_M1_RFMT_SUFFIX_LEN_VALUE_NONE << QMI_M1_RFMT_SUFFIX_LEN_LSB);
    qmi_hw->m[1].rcmd = CMD_READ_QUAD << QMI_M1_RCMD_PREFIX_LSB;

    /*
     * QMI M1 write format — QPI Quad Write (0x38):
     *   All phases on 4 lines, no dummy/wait cycles.
     *   Max frequency 133 MHz (datasheet §8.5).
     */
    qmi_hw->m[1].wfmt =
          (QMI_M1_WFMT_PREFIX_WIDTH_VALUE_Q << QMI_M1_WFMT_PREFIX_WIDTH_LSB)
        | (QMI_M1_WFMT_ADDR_WIDTH_VALUE_Q << QMI_M1_WFMT_ADDR_WIDTH_LSB)
        | (QMI_M1_WFMT_SUFFIX_WIDTH_VALUE_Q << QMI_M1_WFMT_SUFFIX_WIDTH_LSB)
        | (QMI_M1_WFMT_DUMMY_WIDTH_VALUE_Q << QMI_M1_WFMT_DUMMY_WIDTH_LSB)
        | (QMI_M1_WFMT_DUMMY_LEN_VALUE_NONE << QMI_M1_WFMT_DUMMY_LEN_LSB)
        | (QMI_M1_WFMT_DATA_WIDTH_VALUE_Q << QMI_M1_WFMT_DATA_WIDTH_LSB)
        | (QMI_M1_WFMT_PREFIX_LEN_VALUE_8 << QMI_M1_WFMT_PREFIX_LEN_LSB)
        | (QMI_M1_WFMT_SUFFIX_LEN_VALUE_NONE << QMI_M1_WFMT_SUFFIX_LEN_LSB);
    qmi_hw->m[1].wcmd = CMD_WRITE_QUAD << QMI_M1_WCMD_PREFIX_LSB;

    /*
     * Enable writes to XIP memory window 1.
     *
     * XIP memory is read-only by default (RP2350 datasheet §4.4.5,
     * XIP_CTRL.WRITABLE_M1).  Without this bit, writes silently fail
     * and the XIP cache may return stale data.
     */
    xip_ctrl_hw->ctrl |= XIP_CTRL_WRITABLE_M1_BITS;

    restore_interrupts(save);
}

void *psram_init(size_t *size_out)
{
    gpio_set_function(PICO_RP2350_PSRAM_CS_PIN, GPIO_FUNC_XIP_CS1);

    size_t psram_size = get_psram_size();
    if (psram_size == 0) {
        printf("PSRAM not detected (check CS pin %d)\n", PICO_RP2350_PSRAM_CS_PIN);
        return NULL;
    }
    printf("PSRAM detected: %u KB\n", (unsigned)(psram_size / 1024));

    setup_psram();

    /* Verify with a write-readback test via uncached alias */
    volatile uint32_t *test = (volatile uint32_t *)(XIP_NOCACHE_NOALLOC_BASE + 16 * 1024 * 1024);
    test[0] = 0xDEADBEEF;
    test[1] = 0x12345678;
    if (test[0] != 0xDEADBEEF || test[1] != 0x12345678) {
        printf("PSRAM verify failed: %08lx %08lx\n",
               (unsigned long)test[0], (unsigned long)test[1]);
        return NULL;
    }

    if (size_out)
        *size_out = psram_size;

    return (void *)(XIP_BASE + 16 * 1024 * 1024);
}
