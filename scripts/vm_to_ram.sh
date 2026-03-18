#!/bin/sh
# vm_to_ram.sh LIBMRUBY LIBMRUBY_NOVM VM_OBJ VM_RAM_O
#
# Extracts vm.o from libmruby.a, renames every .text.* section to
# .time_critical.* so pico-sdk's linker script places it in SRAM, and
# creates libmruby_novm.a (the archive without vm.o) for separate linking.
#
# Usage:
#   scripts/vm_to_ram.sh libmruby.a libmruby_novm.a mruby_vm_orig.o mruby_vm_ram.o

set -e

LIBMRUBY="$1"
LIBMRUBY_NOVM="$2"
VM_OBJ="$3"
VM_RAM_O="$4"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# 1. Build libmruby_novm.a: copy archive, remove vm.o member.
cp "$LIBMRUBY" "$LIBMRUBY_NOVM"
arm-none-eabi-ar d "$LIBMRUBY_NOVM" vm.o

# 2. Extract vm.o from the original archive.
(cd "$WORKDIR" && arm-none-eabi-ar x "$LIBMRUBY" vm.o)
cp "$WORKDIR/vm.o" "$VM_OBJ"

# 3. Rename every .text.* section to .time_critical.* so pico-sdk places
#    the code in .data (copied from flash to SRAM at boot).
cp "$VM_OBJ" "$VM_RAM_O"
for sec in $(arm-none-eabi-objdump -h "$VM_OBJ" | awk '$2 ~ /^\.text\./{print $2}'); do
    suffix="${sec#.text}"
    arm-none-eabi-objcopy \
        --rename-section "${sec}=.time_critical${suffix}" \
        "$VM_RAM_O" "$VM_RAM_O"
done

echo "vm_to_ram.sh: created $VM_RAM_O and $LIBMRUBY_NOVM"
