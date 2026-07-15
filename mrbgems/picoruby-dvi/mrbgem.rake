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
  font8x8_dir = "#{dir}/lib/fonts/font8x8"
  inter_dir = "#{dir}/lib/fonts/inter"
  outfit_dir = "#{dir}/lib/fonts/outfit"
  source_code_pro_dir = "#{dir}/lib/fonts/source-code-pro"

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

  ruby_cmd = "ruby"

  # M PLUS 1 Medium: full JIS X 0208, 4bpp anti-aliased, compressed
  # (canonical Huffman + zero-run). Rendered at 20px with the baseline forced
  # to row 22 so it aligns with FONT_OUTFIT_22 (ascender 22) in PicoRabbit.
  mplus1_dir = "#{dir}/lib/fonts/mplus-1"
  mplus1_ttf = "#{mplus1_dir}/MPLUS1-Medium.ttf"
  mplus1_dst = "#{include_dir}/font_mplus_1_medium_22.h"
  file mplus1_dst => [mplus1_ttf, ttf2c, include_dir] do
    sh "#{ruby_cmd} #{ttf2c} #{mplus1_ttf} -s 20 --ascent 22 --jis --aa --compress -n mplus_1_medium_22 -o #{mplus1_dst}"
  end

  # M PLUS 1 ExtraBold: full JIS X 0208, 4bpp anti-aliased, compressed.
  # Rendered at 27px with the baseline forced to row 32 so it aligns with
  # FONT_OUTFIT_EXTRABOLD_32 (ascender 32) for PicoRabbit slide titles.
  mplus1_eb_ttf = "#{mplus1_dir}/MPLUS1-ExtraBold.ttf"
  mplus1_eb_dst = "#{include_dir}/font_mplus_1_extrabold_32.h"
  file mplus1_eb_dst => [mplus1_eb_ttf, ttf2c, include_dir] do
    sh "#{ruby_cmd} #{ttf2c} #{mplus1_eb_ttf} -s 27 --ascent 32 --jis --aa --compress -n mplus_1_extrabold_32 -o #{mplus1_eb_dst}"
  end

  # Kanrk09 theme fonts: M PLUS 1 at 32px (body) and 48px (title), for both
  # Latin and Japanese glyphs. Full JIS X 0208 coverage at these sizes does
  # not fit the 6 MB firmware flash window, so the Japanese fonts are
  # subsetted to the symbol/alnum/kana rows (1-5) plus the characters used in
  # the kanrk09 slide deck. Editing the deck regenerates the fonts on the
  # next build. The LATIN/JAPANESE pairs share the point size and baseline;
  # the legacy MEDIUM_22/EXTRABOLD_32 fonts are ascent-named instead (they
  # baseline-match Outfit), which is why these carry an explicit suffix.
  mplus1_medium_ttf = "#{mplus1_dir}/MPLUS1-Medium.ttf"
  kanrk09_deck = "#{project_root}/rootfs/slides/kanrk09.md"
  kanrk09_subset = "--jis-rows 1-5 --chars #{kanrk09_deck}"
  kanrk09_fonts = [
    { src: mplus1_medium_ttf,
      dst: "#{include_dir}/font_mplus_1_medium_32_latin.h",
      args: "-s 32 --aa -n mplus_1_medium_32_latin" },
    { src: mplus1_medium_ttf,
      dst: "#{include_dir}/font_mplus_1_medium_32_japanese.h",
      args: "-s 32 --jis --aa --compress #{kanrk09_subset} -n mplus_1_medium_32_japanese",
      deck: true },
    { src: mplus1_eb_ttf,
      dst: "#{include_dir}/font_mplus_1_extrabold_32_latin.h",
      args: "-s 32 --aa -n mplus_1_extrabold_32_latin" },
    { src: mplus1_eb_ttf,
      dst: "#{include_dir}/font_mplus_1_extrabold_32_japanese.h",
      args: "-s 32 --jis --aa --compress #{kanrk09_subset} -n mplus_1_extrabold_32_japanese",
      deck: true },
    { src: mplus1_eb_ttf,
      dst: "#{include_dir}/font_mplus_1_extrabold_48_latin.h",
      args: "-s 48 --aa -n mplus_1_extrabold_48_latin" },
    { src: mplus1_eb_ttf,
      dst: "#{include_dir}/font_mplus_1_extrabold_48_japanese.h",
      args: "-s 48 --jis --aa --compress #{kanrk09_subset} -n mplus_1_extrabold_48_japanese",
      deck: true },
  ]

  kanrk09_fonts.each do |font|
    deps = [font[:src], ttf2c, include_dir]
    deps << kanrk09_deck if font[:deck]
    file font[:dst] => deps do
      sh "#{ruby_cmd} #{ttf2c} #{font[:src]} #{font[:args]} -o #{font[:dst]}"
    end
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
    { src: "#{outfit_dir}/Outfit-Bold.ttf",
      dst: "#{include_dir}/font_outfit_bold_22.h",
      args: ["-s", "22", "-n", "outfit_bold_22", "--aa"] },
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

  # Source Code Pro fonts (4bpp anti-aliased, monospace)
  source_code_pro_fonts = [
    { src: "#{source_code_pro_dir}/SourceCodePro-Regular.ttf",
      dst: "#{include_dir}/font_source_code_pro_14.h",
      args: ["-s", "14", "-n", "source_code_pro_14", "--aa"] },
    { src: "#{source_code_pro_dir}/SourceCodePro-Bold.ttf",
      dst: "#{include_dir}/font_source_code_pro_bold_14.h",
      args: ["-s", "14", "-n", "source_code_pro_bold_14", "--aa"] },
    { src: "#{source_code_pro_dir}/SourceCodePro-Regular.ttf",
      dst: "#{include_dir}/font_source_code_pro_18.h",
      args: ["-s", "18", "-n", "source_code_pro_18", "--aa"] },
    { src: "#{source_code_pro_dir}/SourceCodePro-Bold.ttf",
      dst: "#{include_dir}/font_source_code_pro_bold_18.h",
      args: ["-s", "18", "-n", "source_code_pro_bold_18", "--aa"] },
    { src: "#{source_code_pro_dir}/SourceCodePro-Regular.ttf",
      dst: "#{include_dir}/font_source_code_pro_20.h",
      args: ["-s", "20", "-n", "source_code_pro_20", "--aa"] },
  ]

  source_code_pro_fonts.each do |font|
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
    { header: "font8x8_basic.h",              var: "font8x8_basic",             sym: "FONT_8X8" },
    { header: "font_mplus_f12r.h",            var: "font_mplus_f12r",           sym: "FONT_MPLUS_12" },
    { header: "font_fixed_4x6.h",             var: "font_fixed_4x6",            sym: "FONT_FIXED_4X6" },
    { header: "font_fixed_5x7.h",             var: "font_fixed_5x7",            sym: "FONT_FIXED_5X7" },
    { header: "font_fixed_6x13.h",            var: "font_fixed_6x13",           sym: "FONT_FIXED_6X13" },
    { header: "font_spleen_5x8.h",            var: "font_spleen_5x8",           sym: "FONT_SPLEEN_5X8" },
    { header: "font_spleen_8x16.h",           var: "font_spleen_8x16",          sym: "FONT_SPLEEN_8X16" },
    { header: "font_spleen_12x24.h",          var: "font_spleen_12x24",         sym: "FONT_SPLEEN_12X24" },
    { header: "font_mplus_j12_combined.h",    var: "font_mplus_j12_wide",       sym: "FONT_MPLUS_J12" },
    { header: "font_mplus_1_medium_22.h",     var: "font_mplus_1_medium_22",    sym: "FONT_MPLUS_1_MEDIUM_22" },
    { header: "font_mplus_1_extrabold_32.h",  var: "font_mplus_1_extrabold_32", sym: "FONT_MPLUS_1_EXTRABOLD_32" },
    { header: "font_mplus_1_medium_32_latin.h",       var: "font_mplus_1_medium_32_latin",       sym: "FONT_MPLUS_1_MEDIUM_32_LATIN" },
    { header: "font_mplus_1_medium_32_japanese.h",    var: "font_mplus_1_medium_32_japanese",    sym: "FONT_MPLUS_1_MEDIUM_32_JAPANESE" },
    { header: "font_mplus_1_extrabold_32_latin.h",    var: "font_mplus_1_extrabold_32_latin",    sym: "FONT_MPLUS_1_EXTRABOLD_32_LATIN" },
    { header: "font_mplus_1_extrabold_32_japanese.h", var: "font_mplus_1_extrabold_32_japanese", sym: "FONT_MPLUS_1_EXTRABOLD_32_JAPANESE" },
    { header: "font_mplus_1_extrabold_48_latin.h",    var: "font_mplus_1_extrabold_48_latin",    sym: "FONT_MPLUS_1_EXTRABOLD_48_LATIN" },
    { header: "font_mplus_1_extrabold_48_japanese.h", var: "font_mplus_1_extrabold_48_japanese", sym: "FONT_MPLUS_1_EXTRABOLD_48_JAPANESE" },
    { header: "font_inter_18.h",              var: "font_inter_18",             sym: "FONT_INTER_18" },
    { header: "font_inter_bold_18.h",         var: "font_inter_bold_18",        sym: "FONT_INTER_BOLD_18" },
    { header: "font_inter_24.h",              var: "font_inter_24",             sym: "FONT_INTER_24" },
    { header: "font_inter_bold_24.h",         var: "font_inter_bold_24",        sym: "FONT_INTER_BOLD_24" },
    { header: "font_outfit_18.h",             var: "font_outfit_18",            sym: "FONT_OUTFIT_18" },
    { header: "font_outfit_bold_18.h",        var: "font_outfit_bold_18",       sym: "FONT_OUTFIT_BOLD_18" },
    { header: "font_outfit_22.h",             var: "font_outfit_22",            sym: "FONT_OUTFIT_22" },
    { header: "font_outfit_bold_22.h",        var: "font_outfit_bold_22",       sym: "FONT_OUTFIT_BOLD_22" },
    { header: "font_outfit_extrabold_32.h",   var: "font_outfit_extrabold_32",  sym: "FONT_OUTFIT_EXTRABOLD_32" },
    { header: "font_inter_symbols_18.h",      var: "font_inter_symbols_18",     sym: "FONT_INTER_SYMBOLS_18" },
    { header: "font_inter_symbols_22.h",      var: "font_inter_symbols_22",     sym: "FONT_INTER_SYMBOLS_22" },
    { header: "font_source_code_pro_14.h",    var: "font_source_code_pro_14",   sym: "FONT_SOURCE_CODE_PRO_14" },
    { header: "font_source_code_pro_bold_14.h", var: "font_source_code_pro_bold_14", sym: "FONT_SOURCE_CODE_PRO_BOLD_14" },
    { header: "font_source_code_pro_18.h",    var: "font_source_code_pro_18",   sym: "FONT_SOURCE_CODE_PRO_18" },
    { header: "font_source_code_pro_bold_18.h", var: "font_source_code_pro_bold_18", sym: "FONT_SOURCE_CODE_PRO_BOLD_18" },
    { header: "font_source_code_pro_20.h",    var: "font_source_code_pro_20",   sym: "FONT_SOURCE_CODE_PRO_20" },
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
    Rake::Task[mplus1_dst].invoke
    Rake::Task[mplus1_eb_dst].invoke
    kanrk09_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    inter_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    outfit_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    source_code_pro_fonts.each { |font| Rake::Task[font[:dst]].invoke }
    Rake::Task[jis_combined_dst].invoke
    Rake::Task[uni2jis_c].invoke
    Rake::Task[registry_dst].invoke
  end
end
