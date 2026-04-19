# Bundler is convenient for local development (ensures the Gemfile gems
# are on the load path) but not required — CI may install gems globally
# via `gem install`. Treat its absence as a no-op so the Rakefile works
# either way.
begin
  require "bundler/setup"
rescue LoadError
end

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

# Run a child process without the parent Bundler's environment. Nested
# rake invocations (PicoRuby, harucom-os-dict) have their own Gemfile
# setup and must not inherit BUNDLE_GEMFILE / RUBYOPT from this rake,
# or they try to load this project's Gemfile and fail.
def sh_unbundled(*cmd, **opts)
  if defined?(Bundler)
    Bundler.with_unbundled_env { sh(*cmd, **opts) }
  else
    sh(*cmd, **opts)
  end
end

desc "Configure, build and produce combined UF2 (default)"
task default: :full_uf2

desc "Run cmake configure"
task :configure do
  sh_unbundled "cmake -B #{BUILD_DIR} -G Ninja"
end

desc "Build firmware"
task build: :configure do
  sh_unbundled "cmake --build #{BUILD_DIR} -j#{nproc}"
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
  sh_unbundled "rake uf2", chdir: DICT_DIR
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
    sh_unbundled "rake clean", chdir: DICT_DIR
  end
end

desc "Clean everything"
task distclean: [:clean, :clean_picoruby, :clean_dict]
