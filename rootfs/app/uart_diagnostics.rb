# uart_diagnostics: debug UART (uart0, TX=GPIO2, RX=GPIO3) health check
#
# The debug UART can go silent while the screen and the rest of the
# system keep working. This app localizes the broken layer without a
# debug probe. It reads the pin and peripheral registers through
# Machine.read_memory, compares them with the values stdio_init_all
# programs at boot, measures whether the UART TX FIFO drains at a
# plausible baud rate, and finally reprograms the pin function selects
# (a no-op when they are already correct).
#
# All output goes to the console, so the report is readable on screen
# while the UART is dead. Each run saves a register snapshot to
# /uart_registers.txt; run once right after boot to record a known-good
# baseline, then again after the UART dies, and the report marks every
# register that changed in between.
#
# How to read the result:
# - A funcsel or pad check fails: the pin was reprogrammed. The final
#   repair step restores it; check the terminal for the test line.
# - Registers pristine but the drain test finishes in microseconds:
#   bytes are dropped before the UART (pico stdio state) or the baud
#   divisor is wrong; compare IBRD/FBRD against the baseline.
# - Registers pristine and the drain test takes milliseconds: the UART
#   is shifting bits out; suspect the wire, the adapter, or the
#   terminal side.

# RP2350 register addresses (uart0 on GPIO2/GPIO3).
IO_BANK0_GPIO2_CTRL = 0x40028014
IO_BANK0_GPIO3_CTRL = 0x4002801C
PADS_BANK0_GPIO2    = 0x4003800C
PADS_BANK0_GPIO3    = 0x40038010
CLK_PERI_CTRL       = 0x40010048
UART0_FR            = 0x40070018
UART0_IBRD          = 0x40070024
UART0_FBRD          = 0x40070028
UART0_LCR_H         = 0x4007002C
UART0_CR            = 0x40070030

# On RP2350, UART0 TX on GPIO2 and RX on GPIO3 use the UART_AUX
# function select (11); funcsel 2 on these pins is CTS/RTS.
UART_AUX_FUNCSEL = 11

SNAPSHOT_PATH = "/uart_registers.txt"

def read_u32(address)
  bytes = Machine.read_memory(address, 4)
  (bytes[3].ord << 24) | (bytes[2].ord << 16) | (bytes[1].ord << 8) | bytes[0].ord
end

def hex(value)
  sprintf("0x%08X", value)
end

# Registers stable across runs; FR is dynamic and shown separately.
REGISTERS = [
  ["gpio2_ctrl", IO_BANK0_GPIO2_CTRL],
  ["gpio3_ctrl", IO_BANK0_GPIO3_CTRL],
  ["pads_gpio2", PADS_BANK0_GPIO2],
  ["pads_gpio3", PADS_BANK0_GPIO3],
  ["clk_peri_ctrl", CLK_PERI_CTRL],
  ["uart0_ibrd", UART0_IBRD],
  ["uart0_fbrd", UART0_FBRD],
  ["uart0_lcr_h", UART0_LCR_H],
  ["uart0_cr", UART0_CR],
]

# File.open of a missing file returns nil instead of raising, so the
# first run starts with an empty baseline.
def load_baseline
  baseline = {}
  content = nil
  begin
    content = File.open(SNAPSHOT_PATH, "r") { |f| f.read }
  rescue
    content = nil
  end
  return baseline unless content
  content.split("\n").each do |line|
    name, value = line.split("=")
    baseline[name] = value.to_i(16) if name && value
  end
  baseline
end

def save_snapshot(values)
  File.open(SNAPSHOT_PATH, "w") do |f|
    values.each { |name, value| f.write "#{name}=#{hex(value)}\n" }
  end
end

def check(label, ok)
  puts "  #{ok ? "ok " : "NG "} #{label}"
  ok
end

puts "uart_diagnostics: uart0 TX=GPIO2 RX=GPIO3"
puts ""

values = {}
REGISTERS.each { |name, address| values[name] = read_u32(address) }
baseline = load_baseline

puts "registers (* = changed since last run):"
REGISTERS.each do |name, _|
  value = values[name]
  mark = " "
  if baseline[name] && baseline[name] != value
    mark = "*"
  end
  line = " #{mark}#{name.ljust(14)} #{hex(value)}"
  line += "  was #{hex(baseline[name])}" if mark == "*"
  puts line
end
puts " (baseline: #{baseline.empty? ? "none, first run" : SNAPSHOT_PATH})"
puts ""

puts "checks:"
all_ok = true
all_ok &= check("GPIO2 funcsel = UART_AUX (TX)",
                (values["gpio2_ctrl"] & 0x1F) == UART_AUX_FUNCSEL)
all_ok &= check("GPIO3 funcsel = UART_AUX (RX)",
                (values["gpio3_ctrl"] & 0x1F) == UART_AUX_FUNCSEL)
all_ok &= check("GPIO2 out/oe overrides off",
                (values["gpio2_ctrl"] & 0xF000) == 0)
all_ok &= check("GPIO2 pad not isolated, output enabled",
                (values["pads_gpio2"] & 0x180) == 0)
all_ok &= check("GPIO3 pad not isolated, input enabled",
                (values["pads_gpio3"] & 0x100) == 0 &&
                (values["pads_gpio3"] & 0x40) != 0)
all_ok &= check("clk_peri enabled",
                (values["clk_peri_ctrl"] & 0x800) != 0)
all_ok &= check("UART enabled, TX enabled (CR)",
                (values["uart0_cr"] & 0x101) == 0x101)
all_ok &= check("8-bit frame, FIFO enabled (LCR_H)",
                (values["uart0_lcr_h"] & 0x70) == 0x70)
all_ok &= check("baud divisor programmed (IBRD > 0)",
                values["uart0_ibrd"] > 0)
puts ""

# Drain timing: 256 chars at 115200 8N1 take about 19 ms past the
# 32-entry TX FIFO. Finishing in microseconds means the bytes never
# waited for a shift register: they were dropped in software or the
# baud divisor is far off.
puts "TX drain test (writes 256 '#' to the UART)..."
filler = "#" * 128
started = Machine.uptime_us
STDOUT.write(filler)
STDOUT.write(filler)
elapsed = Machine.uptime_us - started
puts "  256 chars took #{elapsed} us (expect ~19000 at 115200 baud)"
if elapsed > 10000
  puts "  -> UART is shifting bits out at a plausible rate."
  puts "     If the terminal stays silent the failure is at the pin,"
  puts "     the wire, or the terminal side."
else
  puts "  -> bytes are NOT reaching the shift register: dropped in"
  puts "     pico stdio, or the baud divisor is wrong (see ibrd/fbrd)."
end
puts "  uart0_fr now: #{hex(read_u32(UART0_FR))}"
puts ""

# Repair: reprogram the function selects (also clears pad isolation).
# This is a no-op when the pins are already correct.
puts "repair: GPIO.set_function_at(2, 11) / (3, 11)"
GPIO.set_function_at(2, UART_AUX_FUNCSEL)
GPIO.set_function_at(3, UART_AUX_FUNCSEL)
STDOUT.puts ""
STDOUT.puts "uart_diagnostics: test line after repair"
puts "  test line sent; check the terminal."
puts ""

save_snapshot(values)
puts "snapshot saved to #{SNAPSHOT_PATH}"
puts(all_ok ? "all register checks passed" : "some register checks FAILED (see above)")
