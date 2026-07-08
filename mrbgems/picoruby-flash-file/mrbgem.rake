MRuby::Gem::Specification.new('picoruby-flash-file') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Flash extent maps for files on the LittleFS partition'

  spec.add_dependency 'picoruby-littlefs'
end
