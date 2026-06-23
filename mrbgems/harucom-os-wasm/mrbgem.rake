MRuby::Gem::Specification.new('harucom-os-wasm') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Harucom OS'
  spec.summary = 'WebAssembly boot entry for Harucom OS'

  # ruby_scripts.h (rootfs C arrays) is generated into build/ by the wasm Rakefile
  # (the same location the board's CMake build uses), so add build/ to the include
  # path instead of generating the header inside this gem's src tree.
  spec.cc.include_paths << File.expand_path('../../build', spec.dir)
end
