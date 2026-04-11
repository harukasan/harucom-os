MRuby::Gem::Specification.new('picoruby-syntax-highlight') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Ruby syntax highlighting using Prism lexer'

  spec.add_dependency 'mruby-compiler2'
end
