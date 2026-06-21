MRuby::Gem::Specification.new('harucom-os-wasm') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Harucom OS'
  spec.summary = 'WebAssembly boot entry for Harucom OS'

  # Provides harucom_init(): deploy the rootfs into the emscripten in-memory
  # filesystem and boot mruby. The hardware HAL, Machine_*, the task scheduler
  # HAL and the io-console / env / rng ports come from picoruby's posix ports
  # (auto-compiled under PICORB_PLATFORM_POSIX), so this gem carries no HAL.
  spec.add_dependency 'mruby-compiler2'
end
