MRuby::CrossBuild.new("harucom-os-pico2") do |conf|

  conf.toolchain("gcc")

  conf.cc.defines << "MRB_TICK_UNIT=1"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=10"

  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_32BIT"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "MRB_USE_CUSTOM_RO_DATA_P"
  conf.cc.defines << "MRB_LINK_TIME_RO_DATA_P"
  conf.cc.defines << "NO_CLOCK_GETTIME=1"
  conf.cc.defines << "USE_FAT_FLASH_DISK"

  conf.cc.command = "arm-none-eabi-gcc"
  conf.linker.command = "arm-none-eabi-ld"
  conf.linker.flags << "-static"
  conf.archiver.command = "arm-none-eabi-ar"

  conf.cc.host_command = "gcc"

  conf.cc.flags.flatten!
  conf.cc.flags << "-mcpu=cortex-m33"
  conf.cc.flags << "-mthumb"

  conf.cc.flags << "-fno-strict-aliasing"
  conf.cc.flags << "-fno-unroll-loops"
  conf.cc.flags << "-mslow-flash-data"

  conf.cc.flags << "-fshort-enums"

  conf.cc.flags << "-Wall"
  conf.cc.flags << "-Wno-format"
  conf.cc.flags << "-Wno-unused-function"
  conf.cc.flags << "-ffunction-sections"
  conf.cc.flags << "-fdata-sections"

  conf.microruby

  conf.gembox "minimum"
  conf.gem gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-string-ext"
  conf.gem core: 'picoruby-gpio'
  conf.gem core: 'picoruby-require'
  conf.gem core: 'picoruby-vfs'
  conf.gem core: 'picoruby-filesystem-fat'
  conf.gem File.expand_path('../../mrbgems/picoruby-dvi', __FILE__)
  conf.gem File.expand_path('../../mrbgems/picoruby-usb-host', __FILE__)
end
