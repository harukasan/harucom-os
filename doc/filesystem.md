# Filesystem

FAT filesystem on the on-board 16 MB flash, powered by [FatFs R0.14b][fatfs]
via the [picoruby-filesystem-fat][pr-fat] mrbgem. Ruby scripts stored on
the filesystem can be loaded at runtime via `require`.

[fatfs]: http://elm-chan.org/fsw/ff/
[pr-fat]: https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-filesystem-fat
[pr-vfs]: https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-vfs

## Ruby API

### FAT

Class: `FAT` (provided by [picoruby-filesystem-fat][pr-fat])

- [FAT.new](#fatnewdevice-label)
- [FAT#mkfs](#fatmkfs)
- [FAT#sector_count](#fatsector_count---hash)
- [FAT#exist?](#fatexistpath---bool)
- [FAT#mkdir](#fatmkdirpath)
- [FAT#unlink](#fatunlinkpath)

`FAT` is the filesystem driver that wraps [FatFs][fatfs]. On the Harucom
Board, the flash device is identified by the symbol `:flash`.

```ruby
fat = FAT.new(:flash, label: "HARUCOM")
```

#### FAT.new(device, label:)

Create a FAT driver instance. `device` is `:flash` for on-board flash.
`label` is the volume label used when formatting.

#### FAT#mkfs

Format the volume and set the volume label. Internally calls `f_mkfs`
followed by `f_setlabel`. The volume must be mounted after formatting
for the label to be set. To format without setting a label, call
`fat._mkfs("flash:")` directly.

#### FAT#sector_count -> Hash

Return total and free sector counts as `{total: n, free: m}`.

#### FAT#exist?(path) -> bool

Return whether a file or directory exists at the given path.

#### FAT#mkdir(path)

Create a directory.

#### FAT#unlink(path)

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
The FAT driver is mounted at `/flash` during boot:

```ruby
fat = FAT.new(:flash, label: "HARUCOM")
VFS.mount(fat, "/flash")
$LOAD_PATH = ["/flash"]
```

After mounting, file and directory operations use absolute paths under
the mountpoint.

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
[picoruby-filesystem-fat][pr-fat]'s `FAT::File`.

- [VFS::File.open](#vfsfileopenpath-mode)
- [VFS::File#read](#vfsfilereadsize---string)
- [VFS::File#write](#vfsfilewritedata---integer)
- [VFS::File#seek](#vfsfileseekoffset-whence)
- [VFS::File#tell](#vfsfiletell---integer)
- [VFS::File#size](#vfsfilesize---integer)
- [VFS::File#close](#vfsfileclose)

```ruby
# Write a file
f = VFS::File.open("/flash/hello.txt", "w")
f.write("Hello from Harucom OS!")
f.close

# Read a file
f = VFS::File.open("/flash/hello.txt", "r")
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
is delegated to [picoruby-filesystem-fat][pr-fat]'s `FAT::Dir`.

- [VFS::Dir.open](#vfsdiropenpath)
- [VFS::Dir#read](#vfsdirread---string)
- [VFS::Dir#close](#vfsdirclose)

```ruby
d = VFS::Dir.open("/flash")
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
[flash_disk.c](../src/flash_disk.c).

### FLASH_disk_read

```c
int FLASH_disk_read(BYTE *buff, LBA_t sector, UINT count);
```

Read sectors via memcpy from the XIP-mapped flash address.

### FLASH_disk_write

```c
int FLASH_disk_write(const BYTE *buff, LBA_t sector, UINT count);
```

Erase and program flash sectors. Enables DVI blanking and waits for VSync
before the operation, then copies the source buffer from PSRAM to a static
SRAM buffer before calling `flash_range_program` (QMI command mode makes
PSRAM inaccessible).

### FLASH_disk_erase

```c
int FLASH_disk_erase(void);
```

Bulk erase of the entire filesystem region (8 MB).

### FILE_physical_address

```c
void FILE_physical_address(FIL *fp, uint8_t **addr);
```

Return the XIP-mapped memory address of a file's starting cluster. Used by
the mruby sandbox to execute `.mrb` bytecode directly from flash without
copying to RAM.

### FILE_sector_size

```c
int FILE_sector_size(void);
```

Return the flash sector size (4096 bytes).

## Hardware Configuration

### Flash Layout

The 16 MB flash is divided into two regions:

| Region | Address range | Size |
|--------|---------------|------|
| Firmware (code, data, fonts) | `0x00000000` - `0x007FFFFF` | 8 MB |
| FAT filesystem | `0x00800000` - `0x00FFFFFF` | 8 MB |

The filesystem region is mapped to XIP address `0x10800000`
(`XIP_BASE + FLASH_TARGET_OFFSET`). Reads go through the XIP cache,
so file data is accessible as memory-mapped reads.

Configuration constants (defined in [disk.h](../include/disk.h)):

| Constant | Value | Description |
|----------|-------|-------------|
| `FLASH_TARGET_OFFSET` | `0x00800000` | Byte offset from flash base |
| `FLASH_SECTOR_SIZE` | 4096 | Erase/program unit (from pico-sdk) |
| `FLASH_SECTOR_COUNT` | 2048 | Total sectors (8 MB / 4096) |

## Architecture

### Boot Sequence

Firmware startup initializes DVI output on Core 1, then runs the mruby VM
on Core 0. The bootstrap Ruby script mounts the filesystem before any user
code is loaded.

1. Core 1 starts DVI output and copies the vector table to SRAM so that
   interrupt dispatch does not access flash during flash write operations.
2. Core 0 opens the mruby VM, compiles and runs the bootstrap script.
3. The bootstrap script mounts the filesystem and sets up `$LOAD_PATH`.
4. User scripts on flash are loaded via `require`.

The bootstrap script mounts the FAT volume at `/flash`. On first boot
(no valid FAT volume), `VFS.mount` raises an exception. The rescue block
formats the volume with `fat._mkfs` and retries. `fat._mkfs` is used
instead of `fat.mkfs` because `mkfs` internally calls `setlabel`, which
requires the volume to be already mounted.

```ruby
fat = FAT.new(:flash, label: "HARUCOM")
retry_count = 0
begin
  VFS.mount(fat, "/flash")
rescue => e
  fat._mkfs("flash:")
  retry_count = retry_count + 1
  retry if retry_count == 1
  raise e
end
$LOAD_PATH = ["/flash"]
```

After mounting, `require "main"` searches `$LOAD_PATH` for
`/flash/main.mrb` or `/flash/main.rb`. If found, the file is compiled
(if `.rb`) and executed in a `Sandbox` instance. If not found, a
`LoadError` is raised.

### Flash Write Safety

Flash erase and program operations temporarily disable XIP, making the
entire flash inaccessible. Three mechanisms ensure Core 1 (DVI output)
is not affected:

1. **DVI blanking with VSync synchronization**: `flash_disk.c` calls
   `dvi_set_blanking(true)` followed by `dvi_wait_vsync()` before flash
   operations. The VSync wait ensures that blanking has taken effect (at
   least one blank frame has been output) before XIP is disabled. In text
   mode, the DMA IRQ handler outputs all-black lines from a static SRAM
   buffer instead of rendering from font data (which may reference flash
   .rodata). Graphics mode is unaffected because the framebuffer is
   entirely in SRAM. After the flash operation, `dvi_set_blanking(false)`
   followed by `dvi_wait_vsync()` ensures the DMA descriptors have fully
   transitioned back to normal rendering before the next write.

2. **VTOR in SRAM**: After `dvi_start_mode()` registers the DMA IRQ handler,
   `core1_dvi_entry` copies the vector table to SRAM and updates the VTOR
   register. Without this, the CPU would read handler addresses from the
   flash vector table when an interrupt fires, faulting while XIP is disabled.

3. **SRAM-resident WFI loop**: `core1_dvi_entry` is marked
   `__not_in_flash_func` so the WFI loop executes from SRAM. Without this,
   Core 1 would resume instruction fetch from flash after waking from WFI,
   faulting while XIP is disabled.

Core 0 disables its own interrupts (`save_and_disable_interrupts`) during
`flash_range_erase` and `flash_range_program` to prevent flash-resident IRQ
handlers from running on the core performing the flash operation.

The source buffer for `flash_range_program` must be in SRAM, not PSRAM.
`flash_range_program` puts the QMI controller into flash command mode (CS0),
which makes PSRAM (QMI CS1) inaccessible. `FLASH_disk_write` uses a static
4 KB SRAM buffer (`FLASH_SECTOR_SIZE` bytes) and processes one sector at a
time. For multi-sector writes, each sector is copied from PSRAM to the SRAM
buffer and programmed individually.

### mrbgem Dependencies

The filesystem support requires the following PicoRuby mrbgems, added in
[harucom-os-pico2.rb](../build_config/harucom-os-pico2.rb):

| mrbgem | Role |
|--------|------|
| [picoruby-filesystem-fat][pr-fat] | FAT driver ([FatFs][fatfs] wrapper, disk I/O) |
| [picoruby-vfs][pr-vfs] | Virtual filesystem path routing |
| `picoruby-require` | `require` / `load` with `$LOAD_PATH` search |
| `picoruby-sandbox` | Sandboxed execution of loaded scripts |
| `picoruby-time` | Timestamp support (dependency of FAT and VFS) |
| `picoruby-env` | Environment variables (dependency of VFS) |
| `mruby-string-ext` | `String#start_with?` (required by VFS path matching) |

### Platform HAL Files

| File | Provides |
|------|----------|
| [flash_disk.c](../src/flash_disk.c) | FatFs block device for flash |
| [platform.c](../src/platform.c) | `Platform_name()` returning "RP2350" |
| [env.c](../src/env.c) | `ENV_setenv` / `ENV_unsetenv` / `ENV_get_key_value` stubs |
| [disk.h](../include/disk.h) | Flash layout constants |

## References

- [FatFs][fatfs]: Generic FAT filesystem module for embedded systems
- [picoruby-filesystem-fat][pr-fat]: PicoRuby FAT filesystem mrbgem
- [picoruby-vfs][pr-vfs]: PicoRuby virtual filesystem layer
