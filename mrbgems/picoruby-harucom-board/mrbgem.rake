MRuby::Gem::Specification.new('picoruby-harucom-board') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Harucom Board pin constants (Board module)'

  # Pin values come straight from the board header so the C build and the
  # Ruby Board constants share one source. Add the project include/ path
  # so src/mruby can include boards/harucom_board.h. The header is pure
  # #define with no pico-sdk, so the presym preprocessor resolves it.
  spec.cc.include_paths << File.expand_path('../../../include', __FILE__)
end
