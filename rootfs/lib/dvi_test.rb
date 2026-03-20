# DVI Text API + Machine test
#
# Exercises: clear, put_string, commit, clear_line, clear_range,
#            scroll_up, scroll_down, get_attr, set_attr,
#            puts, print, Machine.uptime_us, Machine.unique_id,
#            Machine.reboot
#
# Each step waits for a keypress so you can visually verify the result.

keyboard = Keyboard.new

def wait_key(kb)
  loop do
    c = kb.read_char
    return c if c
    DVI.wait_vsync
  end
end

def show_step(title, detail, step, kb)
  DVI::Text.clear_line(0, 0x1F)
  DVI::Text.put_string(0, 0, title, 0x1F)
  DVI::Text.clear_line(36, 0x8F)
  s = "[" + step.to_s + "] Press any key"
  DVI::Text.put_string(0, 36, s, 0x8F)
  if detail
    DVI::Text.put_string(0, 35, detail, 0xF0)
  end
  DVI::Text.commit
  wait_key(kb)
end

# Step 1: clear + put_string + commit
DVI::Text.clear(0xF0)
37.times do |r|
  DVI::Text.put_string(0, r, "Row " + r.to_s, 0xF0)
end
show_step("1: clear + put_string", "All 37 rows filled", 1, keyboard)

# Step 2: clear_line
DVI::Text.clear_line(5, 0x4F)
DVI::Text.clear_line(10, 0x2F)
DVI::Text.clear_line(15, 0x6F)
show_step("2: clear_line", "Rows 5,10,15 cleared with colors", 2, keyboard)

# Step 3: clear_range
DVI::Text.clear_range(10, 3, 20, 0x4F)
DVI::Text.clear_range(10, 4, 20, 0x2F)
show_step("3: clear_range", "Cols 10-29 on rows 3-4 cleared", 3, keyboard)

# Step 4: scroll_up
DVI::Text.clear(0xF0)
37.times do |r|
  DVI::Text.put_string(0, r, "Line " + r.to_s, 0xF0)
end
DVI::Text.commit
wait_key(keyboard)
DVI::Text.scroll_up(5, 0xF0)
show_step("4: scroll_up(5)", "Lines shifted up by 5", 4, keyboard)

# Step 5: scroll_down
DVI::Text.scroll_down(3, 0xF0)
show_step("5: scroll_down(3)", "Lines shifted down by 3", 5, keyboard)

# Step 6: get_attr / set_attr (cursor simulation)
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 2, "ABCDEFGHIJ", 0xF0)
DVI::Text.commit
wait_key(keyboard)
5.times do |i|
  attr = DVI::Text.get_attr(i, 2)
  DVI::Text.set_attr(i, 2, (attr & 0x0F) << 4 | (attr >> 4))
end
show_step("6: get_attr/set_attr", "First 5 chars inverted", 6, keyboard)

# Step 7: rapid scroll stress test
DVI::Text.clear(0xF0)
DVI::Text.commit
100.times do |i|
  DVI::Text.scroll_up(1, 0xF0)
  DVI::Text.put_string(0, 36, "Scroll line " + i.to_s, 0xF0)
  DVI::Text.commit
end
show_step("7: rapid scroll (100 lines)", "No tearing expected", 7, keyboard)

# Step 8: Kernel#puts (output to UART)
DVI::Text.clear(0xF0)
puts "Hello from puts! (check UART)"
print "print works too. "
puts "uptime: " + Machine.uptime_formatted
show_step("8: puts/print", "Check UART for output", 8, keyboard)

# Step 9: Machine.uptime_us
DVI::Text.clear(0xF0)
t1 = Machine.uptime_us
sleep_ms 100
t2 = Machine.uptime_us
elapsed = t2 - t1
s = "Elapsed: " + elapsed.to_s + " us (expect ~100000)"
DVI::Text.put_string(0, 2, s, 0xF0)
ok = elapsed > 80000 && elapsed < 200000
DVI::Text.put_string(0, 3, ok ? "OK" : "FAIL", ok ? 0x2F : 0x4F)
show_step("9: Machine.uptime_us", nil, 9, keyboard)

# Step 10: Machine.unique_id
DVI::Text.clear(0xF0)
id = Machine.unique_id
DVI::Text.put_string(0, 2, "ID: " + id, 0xF0)
show_step("10: Machine.unique_id", nil, 10, keyboard)

# Step 11: Machine.reboot
DVI::Text.clear(0xF0)
DVI::Text.put_string(0, 2, "Press any key to reboot...", 0x4F)
DVI::Text.commit
wait_key(keyboard)
Machine.reboot
