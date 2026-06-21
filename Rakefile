require "bundler/setup"

PROJECT_DIR = __dir__
BUILD_DIR   = File.join(PROJECT_DIR, "build")
DICT_DIR    = File.join(PROJECT_DIR, "vendor", "harucom-os-dict")
DICT_UF2    = File.join(DICT_DIR, "build", "dict.uf2")
HARUCOM_UF2 = File.join(BUILD_DIR, "harucom_os.uf2")
FULL_UF2    = File.join(BUILD_DIR, "harucom_os_full.uf2")
MERGE_SCRIPT = File.join(PROJECT_DIR, "scripts", "merge_uf2.rb")

def nproc
  require "etc"
  Etc.nprocessors
end

desc "Configure, build and produce combined UF2 (default)"
task default: :full_uf2

desc "Run cmake configure"
task :configure do
  sh "cmake -B #{BUILD_DIR} -G Ninja"
end

desc "Build firmware"
task build: :configure do
  sh "cmake --build #{BUILD_DIR} -j#{nproc}"
end

desc "Build UF2 (harucom-os only)"
task uf2: :build

# Initialize the harucom-os-dict submodule on demand.
task :dict_submodule do
  unless File.exist?(File.join(DICT_DIR, "Rakefile"))
    sh "git submodule update --init --recursive #{DICT_DIR}"
  end
end

desc "Build dictionary UF2 (vendor/harucom-os-dict)"
task dict_uf2: :dict_submodule do
  sh "rake uf2", chdir: DICT_DIR
end

desc "Build combined UF2 (harucom-os + dict)"
task full_uf2: [:uf2, :dict_uf2] do
  sh "ruby #{MERGE_SCRIPT} -o #{FULL_UF2} #{HARUCOM_UF2} #{DICT_UF2}"

  # Make a version-stamped copy alongside the CMake-produced release file,
  # e.g. harucom_os-<git>-<date>.uf2  ->  harucom_os_full-<git>-<date>.uf2.
  release_uf2 = Dir.glob(File.join(BUILD_DIR, "harucom_os-*.uf2"))
                   .reject { |p| p.include?("_full") }
                   .max_by { |p| File.mtime(p) }
  if release_uf2
    tag = File.basename(release_uf2, ".uf2").sub(/^harucom_os-/, "")
    cp FULL_UF2, File.join(BUILD_DIR, "harucom_os_full-#{tag}.uf2")
  end
end

desc "Flash combined firmware via picotool and reboot"
task flash: :full_uf2 do
  sh "picotool load -f -x #{FULL_UF2}"
end

desc "Clean build directory"
task :clean do
  rm_rf BUILD_DIR
end

desc "Clean PicoRuby build"
task :clean_picoruby do
  picoruby_build = File.join(PROJECT_DIR, "lib", "picoruby", "build")
  rm_rf picoruby_build
  # Recreate .gitignore so the submodule stays clean in git status
  mkdir_p picoruby_build
  File.write(File.join(picoruby_build, ".gitignore"), "*\n!.gitignore\n")
end

desc "Clean dictionary build"
task :clean_dict do
  if File.exist?(File.join(DICT_DIR, "Rakefile"))
    sh "rake clean", chdir: DICT_DIR
  end
end

desc "Clean everything"
task distclean: [:clean, :clean_picoruby, :clean_dict]

# ---------------------------------------------------------------------------
# WebAssembly build (run Harucom OS in the browser via picoruby.wasm)
# ---------------------------------------------------------------------------
PICORUBY_DIR  = File.join(PROJECT_DIR, "lib", "picoruby")
WASM_DIR      = File.join(PROJECT_DIR, "wasm")        # source: index.html, node harness
WASM_OUT      = File.join(BUILD_DIR, "wasm")          # build output (build/ is gitignored)
WASM_CONFIG   = File.join(PROJECT_DIR, "build_config", "harucom-wasm.rb")
WASM_BUILD    = File.join(PICORUBY_DIR, "build", "harucom-wasm")
WASM_HOST     = File.join(PICORUBY_DIR, "build", "host")
WASM_LIBMRUBY = File.join(WASM_BUILD, "lib", "libmruby.a")
WASM_JS       = File.join(WASM_OUT, "harucom.js")
WASM_WASM     = File.join(WASM_OUT, "harucom.wasm")
WASM_INDEX    = File.join(WASM_OUT, "index.html")
ROOTFS_DIR    = File.join(PROJECT_DIR, "rootfs")
ROOTFS_DATA   = File.join(PROJECT_DIR, "mrbgems", "harucom-os-wasm", "src", "ruby_scripts.h")
GEN_RUBY_SCRIPTS = File.join(PROJECT_DIR, "scripts", "gen_ruby_scripts.rb")

# Regenerate ruby_scripts.h only when a rootfs source (or the generator) is
# newer, so an unchanged rootfs does not force harucom_wasm.c to recompile.
file ROOTFS_DATA =>
     (FileList["#{ROOTFS_DIR}/**/*"].exclude { |f| File.directory?(f) } << GEN_RUBY_SCRIPTS) do
  sh "ruby", GEN_RUBY_SCRIPTS, ROOTFS_DIR, ROOTFS_DATA
end

namespace :wasm do
  def require_emcc!
    return if system("emcc --version > /dev/null 2>&1")
    abort "emcc not found on PATH. Activate emscripten first, e.g.:\n" \
          "  source ~/emsdk/emsdk_env.sh"
  end

  desc "Generate rootfs C arrays (ruby_scripts.h) when rootfs/ changes"
  task rootfs: ROOTFS_DATA

  # Copy the static page next to the built module so build/wasm/ is a
  # self-contained directory the server can host.
  def stage_index!
    mkdir_p WASM_OUT
    cp File.join(WASM_DIR, "index.html"), WASM_INDEX
  end

  desc "Build build/wasm/harucom.{js,wasm} (CLEAN=1 to rebuild presym/host from scratch)"
  task build: :rootfs do
    require_emcc!
    if %w[1 true yes].include?(ENV["CLEAN"].to_s.downcase)
      rm_rf WASM_BUILD
      rm_rf WASM_HOST
    end
    mkdir_p WASM_OUT
    # Build libmruby.a with emscripten. Run outside the harucom bundler env so
    # the picoruby submodule build uses its own gems, not this Gemfile.
    Bundler.with_unbundled_env do
      sh({ "MRUBY_CONFIG" => WASM_CONFIG }, "rake", chdir: PICORUBY_DIR)
    end
    # Link libmruby.a into the browser module. harucom_init / mrb_run_step /
    # mrb_tick_wasm are driven by wasm/index.html's run loop.
    exported = '["' + %w[_harucom_init _mrb_run_step _mrb_tick_wasm _malloc _free].join('","') + '"]'
    runtime  = '["' + %w[ccall cwrap UTF8ToString stringToUTF8 lengthBytesUTF8 HEAPU8].join('","') + '"]'
    sh "emcc", "-g0", "-O2",
       "-sWASM=1", "-sMODULARIZE=1", "-sEXPORT_NAME=createHarucomModule",
       "-sEXPORTED_RUNTIME_METHODS=#{runtime}",
       "-sEXPORTED_FUNCTIONS=#{exported}",
       "-sINITIAL_MEMORY=32MB", "-sALLOW_MEMORY_GROWTH=1", "-sSTACK_SIZE=2MB",
       "-sENVIRONMENT=web,node", "-sWASM_ASYNC_COMPILATION=1",
       "-sERROR_ON_UNDEFINED_SYMBOLS=0", "--no-entry",
       WASM_LIBMRUBY, "-o", WASM_JS
    stage_index!
    puts "Built #{WASM_WASM} (#{File.size(WASM_WASM)} bytes)"
  end

  desc "Serve build/wasm/ over HTTP for browser testing (PORT=8000)"
  task :server do
    unless File.exist?(WASM_WASM)
      abort "#{WASM_WASM} not found. Run `rake wasm:build` first."
    end
    stage_index! # pick up any index.html edits without a full rebuild
    port = ENV["PORT"] || "8000"
    puts "Serving #{WASM_OUT} at http://localhost:#{port}/  (Ctrl-C to stop)"
    sh "python3", "-m", "http.server", port, "--bind", "127.0.0.1",
       "--directory", WASM_OUT
  end

  desc "Smoke-test the wasm build headlessly under Node"
  task :test do
    abort "#{WASM_WASM} not found. Run `rake wasm:build` first." unless File.exist?(WASM_WASM)
    sh "node", File.join(WASM_DIR, "run_node.cjs")
  end

  desc "Remove the wasm build output"
  task :clean do
    rm_rf WASM_BUILD
    rm_rf WASM_OUT
  end
end
