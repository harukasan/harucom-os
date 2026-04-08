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
  ttf2c = "#{scripts_dir}/ttf2c.rb"
  font8x8_to_c = "#{scripts_dir}/font8x8_to_c.rb"
  gen_uni2jis = "#{scripts_dir}/gen_uni2jis.rb"
  mplus_dir = "#{dir}/lib/fonts/mplus_bitmap_fonts-2.2.4"
  misc_dir = "#{dir}/lib/fonts/misc-misc"
  spleen_dir = "#{dir}/lib/fonts/spleen"
  denkichip_dir = "#{dir}/lib/fonts/x8y12pxDenkiChip"
  font8x8_dir = "#{dir}/lib/fonts/font8x8"
  adobe_dir = "#{dir}/lib/fonts/adobe-75dpi"
  inter_dir = "#{dir}/lib/fonts/inter"
  outfit_dir = "#{dir}/lib/fonts/outfit"

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
    { src: "#{spleen_dir}/spleen-5x8.bdf",
      dst: "#{include_dir}/font_spleen_5x8.h",
      args: ["-n", "spleen_5x8"] },
    { src: "#{spleen_dir}/spleen-8x16.bdf",
      dst: "#{include_dir}/font_spleen_8x16.h",
      args: ["-n", "spleen_8x16"] },
    { src: "#{spleen_dir}/spleen-12x24.bdf",
      dst: "#{include_dir}/font_spleen_12x24.h",
      args: ["-n", "spleen_12x24"] },
    { src: "#{adobe_dir}/helvR14.bdf",
      dst: "#{include_dir}/font_helvetica_14.h",
      args: ["-n", "helvetica_14"] },
    { src: "#{adobe_dir}/helvB14.bdf",
      dst: "#{include_dir}/font_helvetica_bold_14.h",
      args: ["-n", "helvetica_bold_14"] },
    { src: "#{adobe_dir}/timR14.bdf",
      dst: "#{include_dir}/font_times_14.h",
      args: ["-n", "times_14"] },
    { src: "#{adobe_dir}/timB14.bdf",
      dst: "#{include_dir}/font_times_bold_14.h",
      args: ["-n", "times_bold_14"] },
    { src: "#{adobe_dir}/ncenR14.bdf",
      dst: "#{include_dir}/font_new_century_14.h",
      args: ["-n", "new_century_14"] },
    { src: "#{adobe_dir}/ncenB14.bdf",
      dst: "#{include_dir}/font_new_century_bold_14.h",
      args: ["-n", "new_century_bold_14"] },
    { src: "#{adobe_dir}/helvR18.bdf",
      dst: "#{include_dir}/font_helvetica_18.h",
      args: ["-n", "helvetica_18"] },
    { src: "#{adobe_dir}/helvB18.bdf",
      dst: "#{include_dir}/font_helvetica_bold_18.h",
      args: ["-n", "helvetica_bold_18"] },
    { src: "#{adobe_dir}/timR18.bdf",
      dst: "#{include_dir}/font_times_18.h",
      args: ["-n", "times_18"] },
    { src: "#{adobe_dir}/timB18.bdf",
      dst: "#{include_dir}/font_times_bold_18.h",
      args: ["-n", "times_bold_18"] },
    { src: "#{adobe_dir}/ncenR18.bdf",
      dst: "#{include_dir}/font_new_century_18.h",
      args: ["-n", "new_century_18"] },
    { src: "#{adobe_dir}/ncenB18.bdf",
      dst: "#{include_dir}/font_new_century_bold_18.h",
      args: ["-n", "new_century_bold_18"] },
    { src: "#{adobe_dir}/helvR24.bdf",
      dst: "#{include_dir}/font_helvetica_24.h",
      args: ["-n", "helvetica_24"] },
    { src: "#{adobe_dir}/helvB24.bdf",
      dst: "#{include_dir}/font_helvetica_bold_24.h",
      args: ["-n", "helvetica_bold_24"] },
    { src: "#{adobe_dir}/timR24.bdf",
      dst: "#{include_dir}/font_times_24.h",
      args: ["-n", "times_24"] },
    { src: "#{adobe_dir}/timB24.bdf",
      dst: "#{include_dir}/font_times_bold_24.h",
      args: ["-n", "times_bold_24"] },
    { src: "#{adobe_dir}/ncenR24.bdf",
      dst: "#{include_dir}/font_new_century_24.h",
      args: ["-n", "new_century_24"] },
    { src: "#{adobe_dir}/ncenB24.bdf",
      dst: "#{include_dir}/font_new_century_bold_24.h",
      args: ["-n", "new_century_bold_24"] },
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

  # DenkiChip ASCII (TTF via FreeType)
  project_root = File.expand_path('../..', dir)
  ruby_cmd = "ruby"

  denkichip_ttf = "#{denkichip_dir}/fonts/ttf/x8y12pxDenkiChip.ttf"
  denkichip_dst = "#{include_dir}/font_denkichip.h"
  file denkichip_dst => [denkichip_ttf, ttf2c, include_dir] do
    sh "#{ruby_cmd} #{ttf2c} #{denkichip_ttf} -s 12 -n denkichip -o #{denkichip_dst}"
  end

  # DenkiChip JIS (TTF via FreeType, JIS indexed)
  denkichip_jis_dst = "#{include_dir}/font_denkichip_j.h"
  file denkichip_jis_dst => [denkichip_ttf, ttf2c, include_dir] do
    sh "#{ruby_cmd} #{ttf2c} #{denkichip_ttf} -s 12 --jis -n denkichip_j -o #{denkichip_jis_dst}"
  end

  # Inter anti-aliased fonts (4bpp)
  inter_fonts = [
    { src: "#{inter_dir}/Inter-Regular.ttf",
      dst: "#{include_dir}/font_inter_18.h",
      args: ["-s", "18", "-n", "inter_18", "--aa"] },
    { src: "#{inter_dir}/Inter-Bold.ttf",
      dst: "#{include_dir}/font_inter_bold_18.h",
      args: ["-s", "18", "-n", "inter_bold_18", "--aa"] },
    { src: "#{inter_dir}/Inter-Regular.ttf",
      dst: "#{include_dir}/font_inter_24.h",
      args: ["-s", "24", "-n", "inter_24", "--aa"] },
    { src: "#{inter_dir}/Inter-Bold.ttf",
      dst: "#{include_dir}/font_inter_bold_24.h",
      args: ["-s", "24", "-n", "inter_bold_24", "--aa"] },
  ]

  inter_fonts.each do |font|
    file font[:dst] => [font[:src], ttf2c, include_dir] do
      sh "#{ruby_cmd} #{ttf2c} #{font[:src]} #{font[:args].join(' ')} -o #{font[:dst]}"
    end
  end

  # Outfit fonts (4bpp anti-aliased)
  outfit_fonts = [
    { src: "#{outfit_dir}/Outfit-Regular.ttf",
      dst: "#{include_dir}/font_outfit_18.h",
      args: ["-s", "18", "-n", "outfit_18", "--aa"] },
    { src: "#{outfit_dir}/Outfit-Bold.ttf",
      dst: "#{include_dir}/font_outfit_bold_18.h",
      args: ["-s", "18", "-n", "outfit_bold_18", "--aa"] },
    { src: "#{outfit_dir}/Outfit-Regular.ttf",
      dst: "#{include_dir}/font_outfit_22.h",
      args: ["-s", "22", "-n", "outfit_22", "--aa"] },
    { src: "#{outfit_dir}/Outfit-ExtraBold.ttf",
      dst: "#{include_dir}/font_outfit_extrabold_32.h",
      args: ["-s", "32", "-n", "outfit_extrabold_32", "--aa"] },
    { src: "#{inter_dir}/Inter-Regular.ttf",
      dst: "#{include_dir}/font_inter_symbols_18.h",
      args: ["-s", "18", "-n", "inter_symbols_18", "--aa", "-r", "0x2600-0x26a0"] },
    { src: "#{inter_dir}/Inter-Regular.ttf",
      dst: "#{include_dir}/font_inter_symbols_22.h",
      args: ["-s", "22", "-n", "inter_symbols_22", "--aa", "-r", "0x2600-0x26a0"] },
  ]

  outfit_fonts.each do |font|
    file font[:dst] => [font[:src], ttf2c, include_dir] do
      sh "#{ruby_cmd} #{ttf2c} #{font[:src]} #{font[:args].join(' ')} -o #{font[:dst]}"
    end
  end

  # JIS X 0208 interleaved regular+bold
  jis_combined_dst = "#{include_dir}/font_mplus_j12_combined.h"
  jis_r_src = "#{mplus_dir}/fonts_j/mplus_j12r.bdf"
  jis_b_src = "#{mplus_dir}/fonts_j/mplus_j12b.bdf"
  file jis_combined_dst => [jis_r_src, jis_b_src, bdf2c, include_dir] do
    sh "ruby #{bdf2c} #{jis_r_src} --jis --bold #{jis_b_src} -n mplus_j12_combined -o #{jis_combined_dst}"
  end

  # Unicode-to-JIS conversion table (generates .c and .h)
  uni2jis_c = "#{include_dir}/uni2jis_table.c"
  uni2jis_h = "#{include_dir}/uni2jis_table.h"
  file uni2jis_c => [gen_uni2jis, include_dir] do
    sh "ruby #{gen_uni2jis} -o #{uni2jis_c}"
  end
  file uni2jis_h => uni2jis_c

  # Font registry: single source of truth for C/Ruby font integration.
  # Each entry maps a generated font header to its C variable and Ruby constant.
  # Adding a font here automatically generates the ID constant, font table entry,
  # and Ruby constant (no other files need to be edited).
  font_registry = [
    { header: "font8x8_basic.h",              var: "font8x8_basic",            sym: "FONT_8X8" },
    { header: "font_mplus_f12r.h",            var: "font_mplus_f12r",          sym: "FONT_MPLUS_12" },
    { header: "font_fixed_4x6.h",             var: "font_fixed_4x6",           sym: "FONT_FIXED_4X6" },
    { header: "font_fixed_5x7.h",             var: "font_fixed_5x7",           sym: "FONT_FIXED_5X7" },
    { header: "font_fixed_6x13.h",            var: "font_fixed_6x13",          sym: "FONT_FIXED_6X13" },
    { header: "font_spleen_5x8.h",            var: "font_spleen_5x8",          sym: "FONT_SPLEEN_5X8" },
    { header: "font_spleen_8x16.h",           var: "font_spleen_8x16",         sym: "FONT_SPLEEN_8X16" },
    { header: "font_spleen_12x24.h",          var: "font_spleen_12x24",        sym: "FONT_SPLEEN_12X24" },
    { header: "font_denkichip.h",             var: "font_denkichip",            sym: "FONT_DENKICHIP" },
    { header: "font_mplus_j12_combined.h",    var: "font_mplus_j12_wide",      sym: "FONT_MPLUS_J12" },
    { header: "font_denkichip_j.h",           var: "font_denkichip_j",          sym: "FONT_DENKICHIP_J" },
    { header: "font_helvetica_14.h",          var: "font_helvetica_14",         sym: "FONT_HELVETICA_14" },
    { header: "font_helvetica_bold_14.h",     var: "font_helvetica_bold_14",    sym: "FONT_HELVETICA_BOLD_14" },
    { header: "font_times_14.h",              var: "font_times_14",             sym: "FONT_TIMES_14" },
    { header: "font_times_bold_14.h",         var: "font_times_bold_14",        sym: "FONT_TIMES_BOLD_14" },
    { header: "font_new_century_14.h",        var: "font_new_century_14",       sym: "FONT_NEW_CENTURY_14" },
    { header: "font_new_century_bold_14.h",   var: "font_new_century_bold_14",  sym: "FONT_NEW_CENTURY_BOLD_14" },
    { header: "font_helvetica_18.h",          var: "font_helvetica_18",         sym: "FONT_HELVETICA_18" },
    { header: "font_helvetica_bold_18.h",     var: "font_helvetica_bold_18",    sym: "FONT_HELVETICA_BOLD_18" },
    { header: "font_times_18.h",              var: "font_times_18",             sym: "FONT_TIMES_18" },
    { header: "font_times_bold_18.h",         var: "font_times_bold_18",        sym: "FONT_TIMES_BOLD_18" },
    { header: "font_new_century_18.h",        var: "font_new_century_18",       sym: "FONT_NEW_CENTURY_18" },
    { header: "font_new_century_bold_18.h",   var: "font_new_century_bold_18",  sym: "FONT_NEW_CENTURY_BOLD_18" },
    { header: "font_helvetica_24.h",          var: "font_helvetica_24",         sym: "FONT_HELVETICA_24" },
    { header: "font_helvetica_bold_24.h",     var: "font_helvetica_bold_24",    sym: "FONT_HELVETICA_BOLD_24" },
    { header: "font_times_24.h",              var: "font_times_24",             sym: "FONT_TIMES_24" },
    { header: "font_times_bold_24.h",         var: "font_times_bold_24",        sym: "FONT_TIMES_BOLD_24" },
    { header: "font_new_century_24.h",        var: "font_new_century_24",       sym: "FONT_NEW_CENTURY_24" },
    { header: "font_new_century_bold_24.h",   var: "font_new_century_bold_24",  sym: "FONT_NEW_CENTURY_BOLD_24" },
    { header: "font_inter_18.h",              var: "font_inter_18",             sym: "FONT_INTER_18" },
    { header: "font_inter_bold_18.h",         var: "font_inter_bold_18",        sym: "FONT_INTER_BOLD_18" },
    { header: "font_inter_24.h",              var: "font_inter_24",             sym: "FONT_INTER_24" },
    { header: "font_inter_bold_24.h",         var: "font_inter_bold_24",        sym: "FONT_INTER_BOLD_24" },
    { header: "font_outfit_18.h",              var: "font_outfit_18",             sym: "FONT_OUTFIT_18" },
    { header: "font_outfit_22.h",               var: "font_outfit_22",             sym: "FONT_OUTFIT_22" },
    { header: "font_outfit_extrabold_32.h",    var: "font_outfit_extrabold_32",   sym: "FONT_OUTFIT_EXTRABOLD_32" },
    { header: "font_inter_symbols_18.h",      var: "font_inter_symbols_18",     sym: "FONT_INTER_SYMBOLS_18" },
    { header: "font_inter_symbols_22.h",      var: "font_inter_symbols_22",     sym: "FONT_INTER_SYMBOLS_22" },
  ]

  # Generate dvi_font_registry.h from the registry above.
  # This header provides font ID constants, the font lookup table, and a macro
  # for registering Ruby constants. Regenerated when mrbgem.rake changes.
  registry_dst = "#{include_dir}/dvi_font_registry.h"
  file registry_dst => [__FILE__, include_dir] do
    lines = []
    lines << "// Auto-generated by mrbgem.rake. Do not edit."
    lines << "#ifndef DVI_FONT_REGISTRY_H"
    lines << "#define DVI_FONT_REGISTRY_H"
    lines << ""
    lines << '#include "dvi_font.h"'
    lines << ""
    lines << "// Font ID constants"
    font_registry.each_with_index do |f, i|
      lines << "#define DVI_GRAPHICS_%-30s %d" % [f[:sym], i]
    end
    lines << "#define DVI_GRAPHICS_FONT_COUNT %27d" % font_registry.size
    lines << ""

    # Ruby constant registration macro (MRB_SYM calls are visible to presym scanner)
    lines << "// Register all font constants on a Ruby class."
    lines << "#define DVI_FONT_DEFINE_RUBY_CONSTANTS(mrb, cls) do { \\"
    font_registry.each do |f|
      lines << "    mrb_define_const_id(mrb, cls, MRB_SYM(#{f[:sym]}), " \
               "mrb_fixnum_value(DVI_GRAPHICS_#{f[:sym]})); \\"
    end
    lines << "} while (0)"
    lines << ""

    # Implementation section: font header includes and lookup table.
    # Only expanded when DVI_FONT_REGISTRY_IMPLEMENTATION is defined.
    lines << "#ifdef DVI_FONT_REGISTRY_IMPLEMENTATION"
    lines << ""
    font_registry.map { |f| f[:header] }.uniq.each do |h|
      lines << "#include \"#{h}\""
    end
    lines << ""
    lines << "static const dvi_font_t *const graphics_fonts[] = {"
    font_registry.each do |f|
      lines << "    [DVI_GRAPHICS_%-30s] = &%s," % [f[:sym], f[:var]]
    end
    lines << "};"
    lines << ""
    lines << "#endif // DVI_FONT_REGISTRY_IMPLEMENTATION"
    lines << ""
    lines << "#endif // DVI_FONT_REGISTRY_H"
    lines << ""

    File.write(registry_dst, lines.join("\n"))
    $stderr.puts "Wrote #{registry_dst} (#{font_registry.size} fonts)"
  end

  tasks = Rake.application.top_level_tasks
  if (tasks & %w(default all picoruby:debug picoruby:prod microruby:debug microruby:prod)).any?
    fonts.each { |font| Rake::Task[font[:dst]].invoke }
    Rake::Task[font8x8_dst].invoke
    Rake::Task[denkichip_dst].invoke
    Rake::Task[denkichip_jis_dst].invoke
    inter_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    outfit_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    Rake::Task[jis_combined_dst].invoke
    Rake::Task[uni2jis_c].invoke
    Rake::Task[registry_dst].invoke
  end
end
