MRuby::Gem::Specification.new('picoruby-dvi') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'DVI output for Harucom Board'
  spec.cc.include_paths << "#{dir}/src"
  spec.cc.include_paths << "#{dir}/ports/rp2350/fonts"
end
