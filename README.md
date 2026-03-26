# Harucom OS

Harucom OS is the firmware for [Harucom Board](https://github.com/harukasan/harucom-board), a handmade single-board computer built around the RP2350 microcontroller. It provides a complete programming environment with DVI video output, USB keyboard input, a file system, and Ruby script execution on mruby VM.

## Target Hardware

- [Harucom Board](https://github.com/harukasan/harucom-board)

## Prerequisites

- [Raspberry Pi Pico SDK toolchain](https://github.com/raspberrypi/pico-sdk) (ARM GCC, CMake, Ninja)
- Ruby and Bundler
- [picotool](https://github.com/raspberrypi/picotool) (for flashing)

## Build

```sh
git clone --recursive https://github.com/harukasan/harucom-os.git
cd harucom-os

git sumodule update --init --recursive
bundle install
rake
```

The UF2 firmware file will be generated in the `build/` directory.

### Flash

```sh
rake flash
```

### Clean

```sh
rake clean      # Remove build/
rake distclean  # Remove build/ and PicoRuby build cache
```

## Documentation

Design documents and implementation notes are in the [doc/](doc/) directory:

- [DVI output](doc/dvi.md)
- [P5 drawing library](doc/p5.md)
- [PSRAM driver](doc/psram.md)
- [USB host keyboard](doc/usb-host-keyboard.md)
- [Keyboard input](doc/keyboard-input.md)
- [Filesystem](doc/filesystem.md)

## License

Copyright © 2026 Shunsuke Michii

Licensed under the [MIT License](LICENSE.md).
