MRuby::Gem::Specification.new('harucom-os-wasm') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Harucom OS'
  spec.summary = 'WebAssembly HAL and bootstrap for Harucom OS'

  # Provides the wasm counterparts of src/hal_machine.c, src/hal_task.c and the
  # picoruby-io-console port, so the same Ruby userland that runs on the board
  # runs in the browser. picoruby-machine and picoruby-io-console supply the
  # headers (machine.h, ringbuffer.h, io-console.h) this HAL implements.
  spec.add_dependency 'picoruby-machine'
  spec.add_dependency 'picoruby-io-console'
end
