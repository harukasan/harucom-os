# Host test VM for rootfs scripts: a POSIX picoruby binary with the
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
  # Upstream POSIX builds all run without boxing; 64-bit word boxing
  # is untested there and crashes.
  conf.cc.defines << "MRB_NO_BOXING"

  conf.picoruby

  # The stdlib gembox pulls in the socket gem, which links against SSL.
  conf.linker.libraries << 'ssl'
  conf.linker.libraries << 'crypto'

  # On POSIX the minimum gembox also provides mruby-bin-mrbc and the
  # bin/picoruby executable the test runner spawns.
  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-picotest'
  conf.gem File.expand_path('../../mrbgems/picoruby-synth-native', __FILE__)
end
