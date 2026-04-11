MRuby::Gem::Specification.new('picoruby-ruby-syntax') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Ruby syntax analysis using Prism (highlighting and indentation)'

  spec.add_dependency 'mruby-compiler2'
end
