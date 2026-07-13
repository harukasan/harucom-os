# CRuby orchestrator for the rootfs host tests.
#
# Usage: rake test / rake "test[filter]"   (or: ruby tests/runner.rb [filter])
#
# Picotest's Runner runs here on CRuby to discover *_test.rb files, and
# executes each test class on the picoruby host VM (ENV["RUBY"], built
# from build_config/harucom-os-host-test.rb). Tests live outside
# rootfs/ so they are never flashed to the board.

project_dir = File.expand_path("..", __dir__)
picotest_lib = File.join(project_dir, "lib/picoruby/mrbgems/picoruby-picotest/mrblib")
rootfs_lib = File.join(project_dir, "rootfs/lib")

$LOAD_PATH.unshift picotest_lib   # require "picotest" during discovery
$LOAD_PATH.unshift rootfs_lib     # test files require rootfs libs during discovery

require "picotest"
require "tmpdir"

ENV["RUBY"] ||= File.join(project_dir, "lib/picoruby/build/harucom-host-test/bin/picoruby")
unless File.executable?(ENV["RUBY"])
  abort "Test VM not found: #{ENV["RUBY"]}\nBuild it with: rake test_vm"
end

runner = Picotest::Runner.new(
  File.join(project_dir, "tests"),
  filter: ARGV[0],
  tmpdir: Dir.tmpdir,
  load_files: [File.join(project_dir, "tests", "stubs.rb")],
  load_path: rootfs_lib
)
errors = runner.run
exit(errors == 0 ? 0 : 1)
