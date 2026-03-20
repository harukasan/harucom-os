MRuby::Gem::Specification.new('picoruby-keyboard-input') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'Keyboard input with HID keycode translation for Harucom Board'

  spec.add_dependency 'picoruby-usb-host'
end
