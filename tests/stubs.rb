# Hardware stubs for host tests. Loaded into the target VM (microruby)
# before each test file, replacing the board's C modules so rootfs
# scripts run unmodified. Tests control time through Machine.millis=.

module Machine
  def self.board_millis
    $machine_millis || 0
  end

  def self.millis=(ms)
    $machine_millis = ms
  end
end
