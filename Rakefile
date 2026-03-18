PROJECT_DIR = __dir__
BUILD_DIR   = File.join(PROJECT_DIR, "build")

def nproc
  require "etc"
  Etc.nprocessors
end

desc "Configure and build (default)"
task default: :uf2

desc "Run cmake configure"
task :configure do
  sh "cmake -B #{BUILD_DIR} -G Ninja"
end

desc "Build firmware"
task build: :configure do
  sh "cmake --build #{BUILD_DIR} -j#{nproc}"
end

desc "Build UF2"
task uf2: :build

desc "Flash firmware via picotool"
task flash: :uf2 do
  uf2 = Dir.glob(File.join(BUILD_DIR, "*.uf2")).first
  abort "UF2 not found in #{BUILD_DIR}" unless uf2
  sh "picotool load -f #{uf2}"
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

desc "Clean everything"
task distclean: [:clean, :clean_picoruby]
