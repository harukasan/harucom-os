#ifndef _BOARDS_HARUCOM_BOARD_H
#define _BOARDS_HARUCOM_BOARD_H

// For board detection
#define HARUCOM_BOARD

// --- FLASH ---
#define PICO_FLASH_SIZE_BYTES (16 * 1024 * 1024)

// --- PSRAM ---
#define PICO_RP2350_PSRAM_CS_PIN 0

// --- LED ---
#define PICO_DEFAULT_LED_PIN 23

// --- UART ---
#ifndef PICO_DEFAULT_UART
#define PICO_DEFAULT_UART 0
#endif
#ifndef PICO_DEFAULT_UART_TX_PIN
#define PICO_DEFAULT_UART_TX_PIN 2
#endif
#ifndef PICO_DEFAULT_UART_RX_PIN
#define PICO_DEFAULT_UART_RX_PIN 3
#endif

// --- SPI ---
#ifndef PICO_DEFAULT_SPI
#define PICO_DEFAULT_SPI 0
#endif
#ifndef PICO_DEFAULT_SPI_SCK_PIN
#define PICO_DEFAULT_SPI_SCK_PIN 6
#endif
#ifndef PICO_DEFAULT_SPI_TX_PIN
#define PICO_DEFAULT_SPI_TX_PIN 7
#endif
#ifndef PICO_DEFAULT_SPI_RX_PIN
#define PICO_DEFAULT_SPI_RX_PIN 4
#endif
#ifndef PICO_DEFAULT_SPI_CSN_PIN
#define PICO_DEFAULT_SPI_CSN_PIN 5
#endif

// --- I2C ---
#ifndef PICO_DEFAULT_I2C
#define PICO_DEFAULT_I2C 0
#endif
#ifndef PICO_DEFAULT_I2C_SDA_PIN
#define PICO_DEFAULT_I2C_SDA_PIN 20
#endif
#ifndef PICO_DEFAULT_I2C_SCL_PIN
#define PICO_DEFAULT_I2C_SCL_PIN 21
#endif

// --- DVI (HSTX) ---
#define HARUCOM_DVI_CLK_N_PIN  12
#define HARUCOM_DVI_CLK_P_PIN  13
#define HARUCOM_DVI_D0_N_PIN   14
#define HARUCOM_DVI_D0_P_PIN   15
#define HARUCOM_DVI_D1_N_PIN   16
#define HARUCOM_DVI_D1_P_PIN   17
#define HARUCOM_DVI_D2_N_PIN   18
#define HARUCOM_DVI_D2_P_PIN   19
#define HARUCOM_DVI_HPD_PIN    11

// --- USB Host (PIO) ---
#define HARUCOM_USBH_DP_PIN       8
#define HARUCOM_USBH_DM_PIN       9
#define HARUCOM_USBH_VBUS_EN_PIN  10

// --- USB Device ---
#define PICO_DEFAULT_USB_VBUS_DET_PIN 22

// --- PWM Audio ---
#define HARUCOM_AUDIO_L_PIN 24
#define HARUCOM_AUDIO_R_PIN 25

// --- Buttons (ADC resistor ladder) ---
#define HARUCOM_BUTTONS_0_PIN 28  // ADC2
#define HARUCOM_BUTTONS_1_PIN 29  // ADC3

// --- Platform ---
#ifndef PICO_RP2350A
#define PICO_RP2350A 1
#endif

#endif // _BOARDS_HARUCOM_BOARD_H
