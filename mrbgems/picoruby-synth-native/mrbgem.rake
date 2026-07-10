MRuby::Gem::Specification.new('picoruby-synth-native') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Native buffer kernels for the Synth render DSL'

  # The kernels are tight numeric loops; prefer speed over size for
  # this gem only (the build default is -Os).
  spec.cc.flags << '-O2'
end
