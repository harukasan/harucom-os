# Host test VM for rootfs scripts: a POSIX microruby binary with the
# picotest gem, driven by tests/runner.rb (CRuby orchestrator).
#
# The VM class and the integer/string defines mirror the board build
# (build_config/harucom-os-pico2.rb) so rootfs code behaves the same
# under test as on the RP2350: same mruby VM, MRB_INT64 arithmetic,
# UTF-8 strings, and the same task scheduler tick configuration.
#
# The build is named so its output (build/harucom-host-test/) does not
# clobber the firmware's host tools in build/host/.
MRuby::Build.new('harucom-host-test') do |conf|
  conf.toolchain :gcc

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_TICK_UNIT=1"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=10"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "MRB_UTF8_STRING"
  conf.cc.defines << "MRB_INT64"

  conf.microruby

  # The stdlib gembox pulls in the socket gem, which links against SSL.
  conf.linker.libraries << 'ssl'
  conf.linker.libraries << 'crypto'

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-bin-microruby'
  conf.gem core: 'picoruby-picotest'
  conf.gem File.expand_path('../../mrbgems/picoruby-synth-native', __FILE__)
  conf.gem File.expand_path('../../lib/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-rational', __FILE__)
  # ObjectSpace.count_objects for host-side heap growth diagnostics
  # (not on the board).
  conf.gem File.expand_path('../../lib/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-objectspace', __FILE__)

  # A named build resolves no 'host' fallback, so it must carry its own
  # bytecode compiler (mruby-bin-mrbc2 emits bin/picorbc).
  conf.gem core: 'mruby-bin-mrbc2'
  conf.instance_variable_set :@mrbcfile, "#{conf.build_dir}/bin/picorbc"
end
