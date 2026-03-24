MRuby::Gem::Specification.new('picoruby-dvi') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Shunsuke Michii'
  spec.summary = 'DVI output for Harucom Board'

  spec.cc.include_paths << "#{dir}/src"

  # Generate font headers from BDF sources into build_dir/include
  include_dir = "#{build_dir}/include"
  cc.include_paths << include_dir
  directory include_dir

  scripts_dir = "#{dir}/lib/scripts"
  bdf2c = "#{scripts_dir}/bdf2c.rb"
  font8x8_to_c = "#{scripts_dir}/font8x8_to_c.rb"
  gen_uni2jis = "#{scripts_dir}/gen_uni2jis.rb"
  mplus_dir = "#{dir}/lib/fonts/mplus_bitmap_fonts-2.2.4"
  misc_dir = "#{dir}/lib/fonts/misc-misc"
  font8x8_dir = "#{dir}/lib/fonts/font8x8"

  fonts = [
    { src: "#{mplus_dir}/fonts_e/mplus_f12r.bdf",
      dst: "#{include_dir}/font_mplus_f12r.h",
      args: ["-n", "mplus_f12r"] },
    { src: "#{mplus_dir}/fonts_e/mplus_f12b.bdf",
      dst: "#{include_dir}/font_mplus_f12b.h",
      args: ["-n", "mplus_f12b"] },
    { src: "#{misc_dir}/4x6.bdf",
      dst: "#{include_dir}/font_fixed_4x6.h",
      args: ["-n", "fixed_4x6"] },
    { src: "#{misc_dir}/5x7.bdf",
      dst: "#{include_dir}/font_fixed_5x7.h",
      args: ["-n", "fixed_5x7"] },
    { src: "#{misc_dir}/6x13.bdf",
      dst: "#{include_dir}/font_fixed_6x13.h",
      args: ["-n", "fixed_6x13"] },
  ]

  fonts.each do |font|
    file font[:dst] => [font[:src], bdf2c, include_dir] do
      sh "ruby #{bdf2c} #{font[:src]} #{font[:args].join(' ')} -o #{font[:dst]}"
    end
  end

  # font8x8 (LSB-first -> MSB-first conversion)
  font8x8_src = "#{font8x8_dir}/font8x8_basic.h"
  font8x8_dst = "#{include_dir}/font8x8_basic.h"
  file font8x8_dst => [font8x8_src, font8x8_to_c, include_dir] do
    sh "ruby #{font8x8_to_c} #{font8x8_src} -o #{font8x8_dst}"
  end

  # JIS X 0208 interleaved regular+bold
  jis_combined_dst = "#{include_dir}/font_mplus_j12_combined.h"
  jis_r_src = "#{mplus_dir}/fonts_j/mplus_j12r.bdf"
  jis_b_src = "#{mplus_dir}/fonts_j/mplus_j12b.bdf"
  file jis_combined_dst => [jis_r_src, jis_b_src, bdf2c, include_dir] do
    sh "ruby #{bdf2c} #{jis_r_src} --jis --bold #{jis_b_src} -n mplus_j12_combined -o #{jis_combined_dst}"
  end

  # Unicode-to-JIS conversion table
  uni2jis_dst = "#{include_dir}/uni2jis_table.h"
  file uni2jis_dst => [gen_uni2jis, include_dir] do
    sh "ruby #{gen_uni2jis} -o #{uni2jis_dst}"
  end

  tasks = Rake.application.top_level_tasks
  if (tasks & %w(default all picoruby:debug picoruby:prod microruby:debug microruby:prod)).any?
    fonts.each { |font| Rake::Task[font[:dst]].invoke }
    Rake::Task[font8x8_dst].invoke
    Rake::Task[jis_combined_dst].invoke
    Rake::Task[uni2jis_dst].invoke
  end
end
