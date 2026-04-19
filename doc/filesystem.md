# Filesystem

LittleFS filesystem on the on-board 16 MB flash, powered by [littlefs][lfs]
via the [picoruby-littlefs][pr-lfs] mrbgem. Ruby scripts stored on the
filesystem can be loaded at runtime via `require`.

[lfs]: https://github.com/littlefs-project/littlefs
[pr-lfs]: https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-littlefs
[pr-vfs]: https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-vfs

## Ruby API

### Littlefs

Class: `Littlefs` (provided by [picoruby-littlefs][pr-lfs])

- [Littlefs.new](#littlefsnewdevice-label)
- [Littlefs#mkfs](#littlefsmkfs)
- [Littlefs#sector_count](#littlefssector_count---hash)
- [Littlefs#exist?](#littlefsexistpath---bool)
- [Littlefs#mkdir](#littlefsmkdirpath)
- [Littlefs#unlink](#littlefsunlinkpath)

`Littlefs` is the filesystem driver that wraps [littlefs][lfs]. On the
Harucom Board, the flash device is identified by the symbol `:flash`.

```ruby
lfs = Littlefs.new(:flash, label: "HARUCOM")
```

#### Littlefs.new(device, label:)

Create a LittleFS driver instance. `device` is `:flash` for on-board
flash. `label` is the volume label returned by `getlabel`; LittleFS does
not persist the label on the medium, so it is only used in-memory by
this driver.

#### Littlefs#mkfs

Format the volume. Internally calls `lfs_format`. Mount is required
before and after to access the fresh volume.

#### Littlefs#sector_count -> Hash

Return total and free sector counts as `{total: n, free: m}`.

#### Littlefs#exist?(path) -> bool

Return whether a file or directory exists at the given path.

#### Littlefs#mkdir(path)

Create a directory.

#### Littlefs#unlink(path)

Delete a file.

### VFS

Class: `VFS` (provided by [picoruby-vfs][pr-vfs])

- [VFS.mount](#vfsmountdriver-mountpoint)
- [VFS.unmount](#vfsunmountdriver)
- [VFS.pwd](#vfspwd---string)
- [VFS.chdir](#vfschdirpath)
- [VFS.exist?](#vfsexistpath---bool)
- [VFS.mkdir](#vfsmkdirpath)
- [VFS.unlink](#vfsunlinkpath)
- [VFS.rename](#vfsrenamefrom-to)

`VFS` provides a unified path namespace over mounted filesystem drivers.
The LittleFS driver is mounted at `/` during boot:

```ruby
lfs = Littlefs.new(:flash, label: "HARUCOM")
VFS.mount(lfs, "/")
$LOAD_PATH = ["/lib"]
```

After mounting, file and directory operations use absolute paths.

#### VFS.mount(driver, mountpoint)

Mount a filesystem driver at the given path. The mountpoint must start
with `/`. Internally calls `driver.mount(mountpoint)`.

#### VFS.unmount(driver)

Unmount a previously mounted driver.

#### VFS.pwd -> String

Return the current working directory.

#### VFS.chdir(path)

Change the current working directory.

#### VFS.exist?(path) -> bool

Return whether a file or directory exists.

#### VFS.mkdir(path)

Create a directory.

#### VFS.unlink(path)

Delete a file.

#### VFS.rename(from, to)

Rename a file or directory. Both paths must be on the same volume.

### VFS::File

`VFS::File` is provided by [picoruby-vfs][pr-vfs]. File I/O methods
(`read`, `write`, `seek`, `tell`, `size`, `close`) are delegated to
[picoruby-littlefs][pr-lfs]'s `Littlefs::File`.

- [VFS::File.open](#vfsfileopenpath-mode)
- [VFS::File#read](#vfsfilereadsize---string)
- [VFS::File#write](#vfsfilewritedata---integer)
- [VFS::File#seek](#vfsfileseekoffset-whence)
- [VFS::File#tell](#vfsfiletell---integer)
- [VFS::File#size](#vfsfilesize---integer)
- [VFS::File#close](#vfsfileclose)

```ruby
# Write a file
f = VFS::File.open("/hello.txt", "w")
f.write("Hello from Harucom OS!")
f.close

# Read a file
f = VFS::File.open("/hello.txt", "r")
content = f.read(256)
f.close
```

#### VFS::File.open(path, mode)

Open a file. Mode is `"r"` (read), `"w"` (write/create/truncate), or
`"a"` (append).

#### VFS::File#read(size) -> String

Read up to `size` bytes and return as a string.

#### VFS::File#write(data) -> Integer

Write data to the file. Returns the number of bytes written.

#### VFS::File#seek(offset, whence)

Set the file position. `whence` is 0 (SET), 1 (CUR), or 2 (END).

#### VFS::File#tell -> Integer

Return the current file position.

#### VFS::File#size -> Integer

Return the file size in bytes.

#### VFS::File#close

Close the file and flush pending writes.

### VFS::Dir

`VFS::Dir` is provided by [picoruby-vfs][pr-vfs]. Directory iteration
is delegated to [picoruby-littlefs][pr-lfs]'s `Littlefs::Dir`.

- [VFS::Dir.open](#vfsdiropenpath)
- [VFS::Dir#read](#vfsdirread---string)
- [VFS::Dir#close](#vfsdirclose)

```ruby
d = VFS::Dir.open("/")
while (entry = d.read)
  # entry is a filename string
end
d.close
```

#### VFS::Dir.open(path)

Open a directory for reading entries.

#### VFS::Dir#read -> String

Read the next directory entry. Returns `nil` at end of directory.

#### VFS::Dir#close

Close the directory.

## C API

Defined in [disk.h](../include/disk.h) and
[flash_hal.c](../ports/picoruby-littlefs/flash_hal.c).

### littlefs_hal_init_config

```c
void littlefs_hal_init_config(struct lfs_config *cfg);
```

Populate an `lfs_config` with the Harucom-Board-specific read, prog,
erase, and sync callbacks. Called by `littlefs_ensure_mounted` before
the first `lfs_mount`.

### littlefs_hal_erase_all

```c
void littlefs_hal_erase_all(void);
```

Bulk erase the entire filesystem region (8 MB). Used by `Littlefs#erase`
to reset the volume without a full format.

## Hardware Configuration

### Flash Layout

The 16 MB flash is divided into two regions:

| Region | Address range | Size |
|--------|---------------|------|
| Firmware (code, data, fonts) | `0x00000000` - `0x007FFFFF` | 8 MB |
| LittleFS filesystem | `0x00800000` - `0x00FFFFFF` | 8 MB |

The filesystem region is mapped to XIP address `0x10800000`
(`XIP_BASE + FLASH_TARGET_OFFSET`). Reads go through the XIP cache,
so file data is accessible as memory-mapped reads.

Configuration constants (defined in [disk.h](../include/disk.h)):

| Constant | Value | Description |
|----------|-------|-------------|
| `FLASH_TARGET_OFFSET` | `0x00800000` | Byte offset from flash base |
| `FLASH_SECTOR_SIZE` | 4096 | Erase/program unit (from pico-sdk) |
| `FLASH_SECTOR_COUNT` | 2048 | Total sectors (8 MB / 4096) |

LittleFS configuration in [flash_hal.c](../ports/picoruby-littlefs/flash_hal.c):

| Field | Value |
|-------|-------|
| `read_size` / `prog_size` | 256 (`FLASH_PAGE_SIZE`) |
| `block_size` | 4096 (`FLASH_SECTOR_SIZE`) |
| `block_count` | 2048 (`FLASH_SECTOR_COUNT`) |
| `block_cycles` | 500 |
| `cache_size` | 256 |
| `lookahead_size` | 16 |

## Architecture

### Boot Sequence

Firmware startup initializes PSRAM, mounts LittleFS and deploys Ruby
scripts to flash, then launches DVI on Core 1 and the mruby VM on
Core 0.

1. Core 0 initializes PSRAM so the Ruby heap is available.
2. Core 0 calls `init_rootfs()` which mounts LittleFS (auto-formatting
   on corruption), checks `ROOTFS_HASH` against the firmware-embedded
   hash, and rewrites all scripts if they differ.
3. Core 1 starts DVI output and copies the vector table to SRAM so that
   interrupt dispatch does not access flash.
4. Core 0 opens the mruby VM, compiles and runs the bootstrap script.
5. The bootstrap script wraps the already-mounted LittleFS instance in a
   `Littlefs` driver, registers it with `VFS`, and sets up `$LOAD_PATH`.
6. `load "/system.rb"` loads the system entry point, which starts
   background services and loads the application via `require`.

Ruby scripts are stored in the `rootfs/` directory of the source tree.
At build time, `scripts/gen_ruby_scripts.rb` converts them to C byte
arrays in `ruby_scripts.h`. At boot, `init_rootfs()` writes them to
flash before the mruby VM starts.

The bootstrap script simply mounts the already-initialized volume:

```ruby
lfs = Littlefs.new(:flash, label: "HARUCOM")
VFS.mount(lfs, "/")
$LOAD_PATH = ["/lib"]

load "/system.rb"
```

Because `Littlefs.new` / `VFS.mount` call into `littlefs_ensure_mounted`,
which is a no-op after `init_rootfs()` has already mounted the volume,
no format-retry dance is needed in Ruby. If the filesystem is absent or
corrupted, `init_rootfs()` formats it automatically on boot.

`/system.rb` is the system entry point (analogous to DOS `COMMAND.COM`).
It starts the USB host background task and loads the application.
Libraries under `/lib/` are loaded via `require`, which searches
`$LOAD_PATH` for `.mrb` then `.rb` files.

### Flash Write Safety

Flash erase and program operations temporarily disable XIP, making the
entire flash inaccessible. Core-1 DVI output continues safely because:

1. **VTOR in SRAM**: After `dvi_start_mode()` registers the DMA IRQ
   handler, `core1_dvi_entry` copies the vector table to SRAM and
   updates the VTOR register. Without this, the CPU would read handler
   addresses from the flash vector table when an interrupt fires,
   faulting while XIP is disabled.
2. **SRAM-resident WFI loop**: `core1_dvi_entry` is marked
   `__not_in_flash_func` so the WFI loop and DMA IRQ handler execute
   from SRAM. Without this, Core 1 would resume instruction fetch from
   flash after waking from WFI.
3. **SRAM-resident VRAM and font cache**: Text-mode rendering reads
   only from SRAM-resident VRAM and the pre-expanded font cache, so
   the scanline renderer never touches flash during output.

Core 0 disables its own interrupts (`save_and_disable_interrupts`) during
`flash_range_erase` and `flash_range_program` to prevent flash-resident
IRQ handlers from running on the core performing the flash operation.

The source buffer for `flash_range_program` must be in SRAM, not PSRAM.
`flash_range_program` puts the QMI controller into flash command mode
(CS0), which makes PSRAM (QMI CS1) inaccessible. `lfs_flash_prog` in
[flash_hal.c](../ports/picoruby-littlefs/flash_hal.c) uses a static 4 KB
SRAM staging buffer and processes one chunk at a time. Each chunk is
copied from the caller's buffer (which may live in PSRAM) to the SRAM
staging buffer before programming.

### XIP Execution of Compiled Bytecode

The sandbox runtime (picoruby-sandbox) can execute `.mrb` bytecode
directly from XIP-mapped flash when the underlying driver supports it.
LittleFS does not guarantee contiguous allocation, so
`Littlefs#contiguous?` always returns `false` and `Littlefs::File` does
not expose `physical_address`. The sandbox detects this via
`respond_to?(:physical_address)` and falls back to reading the file
into the mruby heap before execution. On the Harucom Board this
trade-off costs some heap memory per loaded script but functionality
is preserved.

### mrbgem Dependencies

The filesystem support requires the following PicoRuby mrbgems, pulled
in by the `core` gembox and [harucom-os-pico2.rb](../build_config/harucom-os-pico2.rb):

| mrbgem | Role |
|--------|------|
| [picoruby-littlefs][pr-lfs] | LittleFS driver and Ruby bindings |
| [picoruby-vfs][pr-vfs] | Virtual filesystem path routing |
| `picoruby-require` | `require` / `load` with `$LOAD_PATH` search |
| `picoruby-sandbox` | Sandboxed execution of loaded scripts |
| `picoruby-time` | Timestamp support (dependency of LittleFS and VFS) |
| `picoruby-env` | Environment variables (dependency of VFS) |
| `mruby-string-ext` | `String#start_with?` (required by VFS path matching) |

### Platform HAL Files

| File | Provides |
|------|----------|
| [flash_hal.c](../ports/picoruby-littlefs/flash_hal.c) | LittleFS HAL (read/prog/erase/sync) for flash |
| [init_rootfs.c](../src/init_rootfs.c) | Initialize root filesystem (mount, auto-format, deploy scripts) |
| [platform.c](../src/platform.c) | `Platform_name()` returning "RP2350" |
| [env.c](../src/env.c) | `ENV_setenv` / `ENV_unsetenv` / `ENV_get_key_value` no-op stubs for picoruby-env |
| [disk.h](../include/disk.h) | Flash layout constants |

### Build Tools

| File | Provides |
|------|----------|
| [gen_ruby_scripts.rb](../scripts/gen_ruby_scripts.rb) | Convert `rootfs/*.rb` to C byte arrays (`ruby_scripts.h`) |

## References

- [littlefs][lfs]: Fail-safe filesystem designed for microcontrollers
- [picoruby-littlefs][pr-lfs]: PicoRuby LittleFS filesystem mrbgem
- [picoruby-vfs][pr-vfs]: PicoRuby virtual filesystem layer
