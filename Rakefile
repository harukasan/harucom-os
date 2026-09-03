require "bundler/setup"

PROJECT_DIR = __dir__
BUILD_DIR   = File.join(PROJECT_DIR, "build")
DICT_DIR    = File.join(PROJECT_DIR, "vendor", "harucom-os-dict")
DICT_UF2    = File.join(DICT_DIR, "build", "dict.uf2")
DICT_BIN    = File.join(DICT_DIR, "build", "dict.bin")
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

# Build just the raw HCDK image (no UF2 wrapper) for the wasm --embed-file step.
file DICT_BIN => :dict_submodule do
  sh "rake build/dict.bin", chdir: DICT_DIR
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

PICORUBY_DIR = File.join(PROJECT_DIR, "lib", "picoruby")
HOST_TEST_CONFIG = File.join(PROJECT_DIR, "build_config", "harucom-os-host-test.rb")
HOST_TEST_VM = File.join(PICORUBY_DIR, "build", "harucom-host-test", "bin", "picoruby")

desc "Build the host test VM (picoruby with board-parity defines)"
task :test_vm do
  sh({ "MRUBY_CONFIG" => HOST_TEST_CONFIG }, "rake all", chdir: PICORUBY_DIR)
end

# Rebuild when the VM is missing or the build config is newer. A config
# change alters the gem set, which invalidates the cached picoruby build,
# so clear it first. A picoruby submodule bump is not detected; run
# rake test_vm after one.
file HOST_TEST_VM => HOST_TEST_CONFIG do
  rm_rf File.join(PICORUBY_DIR, "build", "harucom-host-test")
  Rake::Task[:test_vm].invoke
end

desc "Run host tests for rootfs scripts (tests/, never flashed)"
task :test, [:filter] => [HOST_TEST_VM] do |_t, args|
  runner = File.join(PROJECT_DIR, "tests", "runner.rb")
  sh({ "RUBY" => HOST_TEST_VM }, "ruby #{runner} #{args[:filter]}".strip)
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
# PICORUBY_DIR is defined above with the host-test paths.
WASM_DIR      = File.join(PROJECT_DIR, "wasm")        # source: index.html, js, tests
WASM_OUT      = File.join(BUILD_DIR, "wasm")          # build output (build/ is gitignored)
WASM_CONFIG   = File.join(PROJECT_DIR, "build_config", "harucom-wasm.rb")
WASM_BUILD    = File.join(PICORUBY_DIR, "build", "harucom-wasm")
WASM_HOST     = File.join(PICORUBY_DIR, "build", "mrbc") # host tools (mrbc)
WASM_LIBMRUBY = File.join(WASM_BUILD, "lib", "libmruby.a")
WASM_JS       = File.join(WASM_OUT, "harucom.js")
WASM_WASM     = File.join(WASM_OUT, "harucom.wasm")
ROOTFS_DIR    = File.join(PROJECT_DIR, "rootfs")
# Generated into build/, the same path the board's CMake build uses
# (CMAKE_BINARY_DIR/ruby_scripts.h), so the header lives in one place and not in
# the gem source tree. harucom-os-wasm/mrbgem.rake adds build/ to its include
# path so harucom_wasm.c can #include it.
ROOTFS_DATA   = File.join(BUILD_DIR, "ruby_scripts.h")
GEN_RUBY_SCRIPTS = File.join(PROJECT_DIR, "scripts", "gen_ruby_scripts.rb")

# Regenerate ruby_scripts.h only when a rootfs source (or the generator) is
# newer, so an unchanged rootfs does not force harucom_wasm.c to recompile.
file ROOTFS_DATA =>
     (FileList["#{ROOTFS_DIR}/**/*"].exclude { |f| File.directory?(f) } << GEN_RUBY_SCRIPTS) do
  mkdir_p BUILD_DIR
  sh "ruby", GEN_RUBY_SCRIPTS, ROOTFS_DIR, ROOTFS_DATA
end

namespace :wasm do
  # Probe outside the bundler env, the same way the build runs emcc: the bundler
  # env breaks emcc's bundled Python, so probing inside it would report a
  # missing emcc on a machine where emsdk_env.sh has been sourced.
  def require_emcc!
    ok = Bundler.with_unbundled_env { system("emcc --version > /dev/null 2>&1") }
    return if ok
    abort "emcc not found on PATH. Activate emscripten first (source emsdk_env.sh)."
  end

  # npm ci when the installed tree is missing or older than the lockfile, so a
  # fresh worktree installs once and a dependency change is picked up, without
  # reinstalling on every build.
  def npm_install!(dir)
    stamp = File.join(dir, "node_modules", ".package-lock.json")
    lock = File.join(dir, "package-lock.json")
    return if File.exist?(stamp) && File.exist?(lock) && File.mtime(stamp) >= File.mtime(lock)
    return if File.exist?(stamp) && !File.exist?(lock)
    # ci for a pinned tree, install where there is no lockfile to honour.
    sh "npm", File.exist?(lock) ? "ci" : "install", "--prefix", dir
  end

  # Build the React shell into wasm/ui/dist.
  def build_ui!
    ui = File.join(WASM_DIR, "ui")
    npm_install!(ui)
    sh "npm", "run", "--prefix", ui, "build"
  end

  # Copy the static page, the engine modules and the built shell next to the
  # wasm module so build/wasm/ is a self-contained directory the server can host.
  def stage_page!
    mkdir_p WASM_OUT
    cp File.join(WASM_DIR, "index.html"), File.join(WASM_OUT, "index.html")
    rm_rf File.join(WASM_OUT, "js")
    cp_r File.join(WASM_DIR, "js"), File.join(WASM_OUT, "js")
    rm_rf File.join(WASM_OUT, "ui")
    cp_r File.join(WASM_DIR, "ui", "dist"), File.join(WASM_OUT, "ui")
  end

  # A coarse mtime signature of the staged sources, so the dev server can restage
  # when an index.html, js or shell edit changes them.
  def stage_signature
    Dir.glob([File.join(WASM_DIR, "index.html"),
              File.join(WASM_DIR, "js", "**", "*"),
              File.join(WASM_DIR, "ui", "src", "**", "*"),
              File.join(WASM_DIR, "ui", "package.json"),
              File.join(WASM_DIR, "ui", "vite.config.ts")]).sort.map do |f|
      File.file?(f) ? File.mtime(f).to_f : 0.0
    end
  end

  desc "Generate rootfs C arrays (ruby_scripts.h) when rootfs/ changes"
  task rootfs: ROOTFS_DATA

  desc "Build build/wasm/harucom.{js,wasm} (CLEAN=1 to rebuild presym/host from scratch)"
  task build: [:rootfs, DICT_BIN] do
    require_emcc!
    if %w[1 true yes].include?(ENV["CLEAN"].to_s.downcase)
      rm_rf WASM_BUILD
      rm_rf WASM_HOST
    end
    mkdir_p WASM_OUT
    # Build libmruby.a with emscripten outside this project's bundler env: the
    # bundler env breaks emcc's bundled Python. The picoruby-dvi font generation
    # still works because freetype is installed as a system gem.
    Bundler.with_unbundled_env do
      sh({ "MRUBY_CONFIG" => WASM_CONFIG }, "rake", chdir: PICORUBY_DIR)
    end
    # Link libmruby.a into the browser module. This intentionally differs from
    # the picoruby-wasm gem's own link task: it exports harucom_init (not
    # picorb_init) and targets web,node without EXPORT_ES6 so the node tests
    # (wasm/tests/) can require() it. harucom_init / mrb_run_step / mrb_tick_wasm
    # are driven by the run loop in wasm/js/engine/runloop.js.
    exported = '["' + %w[
      _harucom_init _mrb_run_step _mrb_tick_wasm
      _harucom_dvi_framebuffer _harucom_dvi_width _harucom_dvi_height
      _harucom_dvi_frame_count
      _harucom_kbd_set_state
      _harucom_audio_pull _harucom_audio_sample_rate _harucom_audio_report
      _harucom_pad_set
      _malloc _free
    ].join('","') + '"]'
    runtime  = '["' + %w[ccall UTF8ToString stringToUTF8 lengthBytesUTF8 HEAPU8 HEAPF32 FS].join('","') + '"]'
    sh "emcc", "-g0", "-O2",
       "-sWASM=1", "-sMODULARIZE=1", "-sEXPORT_NAME=createHarucomModule",
       "-sEXPORTED_RUNTIME_METHODS=#{runtime}",
       "-sEXPORTED_FUNCTIONS=#{exported}",
       "-sINITIAL_MEMORY=32MB", "-sALLOW_MEMORY_GROWTH=1", "-sSTACK_SIZE=2MB",
       "-sENVIRONMENT=web,node", "-sWASM_ASYNC_COMPILATION=1",
       "--no-entry",
       # The board reads the dictionary from flash through XIP. The browser has
       # no XIP, so embed the image and let dict_wasm_init load it from MEMFS.
       "--embed-file", "#{DICT_BIN}@/dict.bin",
       WASM_LIBMRUBY, "-o", WASM_JS
    build_ui!
    stage_page!
    puts "Built #{WASM_WASM} (#{File.size(WASM_WASM)} bytes)"
  end

  desc "Build the React shell into wasm/ui/dist (no emcc needed)"
  task :ui do
    build_ui!
  end

  desc "Type-check and unit-test the React shell"
  task :ui_test do
    ui = File.join(WASM_DIR, "ui")
    npm_install!(ui)
    sh "npm", "run", "--prefix", ui, "typecheck"
    sh "npm", "run", "--prefix", ui, "test"
  end

  desc "Serve build/wasm/ over HTTP for browser testing (PORT=8000)"
  task :server do
    require "webrick"
    unless File.exist?(WASM_WASM)
      abort "#{WASM_WASM} not found. Run `rake wasm:build` first."
    end
    build_ui!   # the shell bundle is derived output, so build before the first stage
    stage_page! # pick up any index.html / js / ui edits without a full rebuild
    # Restage on change, so editing the browser glue shows up on a plain reload
    # (no emcc rebuild, no restart).
    restager = Thread.new do
      sig = stage_signature
      loop do
        sleep 1
        now = stage_signature
        next if now == sig
        sig = now
        begin
          build_ui!
          stage_page!
          puts "Restaged wasm/ (js / index.html / ui change)"
        rescue => e
          warn "Restage failed: #{e.message}"
        end
      end
    end
    restager.abort_on_exception = false
    port = Integer(ENV["PORT"] || 8000)
    # WEBrick has no .wasm type, and without application/wasm the browser
    # refuses the streaming instantiation and falls back to a slower path.
    mime = WEBrick::HTTPUtils::DefaultMimeTypes.merge(
      "wasm" => "application/wasm", "js" => "text/javascript"
    )
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: port, DocumentRoot: WASM_OUT,
      MimeTypes: mime, Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
    )
    # Send no-store so a plain reload always picks up the restaged js / css.
    # Without it the browser serves them from cache and edits appear to do
    # nothing until a hard reload.
    server.config[:RequestCallback] = proc do |_req, res|
      res["Cache-Control"] = "no-store, max-age=0"
    end
    ["INT", "TERM"].each { |sig| trap(sig) { server.shutdown } }
    puts "Serving #{WASM_OUT} at http://localhost:#{port}/  (Ctrl-C to stop)"
    server.start
  end

  desc "Smoke-test the wasm build headlessly under Node (node:test runner)"
  task :test do
    abort "#{WASM_WASM} not found. Run `rake wasm:build` first." unless File.exist?(WASM_WASM)
    npm_install!(WASM_DIR) # jsdom, which the harness builds its page in
    # node --test expands the glob itself (a bare directory arg is treated as a
    # module path, not a discovery root). --test-force-exit because a file that
    # boots the shell leaves handles open that nothing can close from a test: the
    # emscripten runtime and React's scheduler both keep the event loop alive, so
    # the run would pass and then hang.
    sh "node", "--test", "--test-force-exit", File.join(WASM_DIR, "tests", "*.test.cjs")
  end

  desc "Remove the wasm build output"
  task :clean do
    rm_rf WASM_BUILD
    rm_rf WASM_OUT
  end
end
