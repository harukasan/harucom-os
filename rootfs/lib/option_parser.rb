# OptionParser: Command-line option parser
#
# Simplified implementation compatible with CRuby's optparse interface.
# Supports short options (-n), options with arguments (-n NUM),
# and automatic -h help display.
#
# Usage:
#   opts = OptionParser.new
#   opts.banner = "Usage: head [options] <file>"
#   opts.on("-n NUM", "Number of lines") { |v| ... }
#   opts.parse!(ARGV)

class OptionParser
  attr_accessor :banner

  def initialize
    @banner = nil
    @options = []
  end

  # Register an option.
  #
  # If the flag string contains a space (e.g. "-n NUM"), the option
  # takes an argument and the block receives the argument string.
  # Otherwise, the option is a boolean flag and the block is called
  # with no arguments.
  def on(flag_spec, description, &block)
    parts = flag_spec.split(" ", 2)
    flag = parts[0]
    value_name = parts[1]
    @options << { flag: flag, value_name: value_name, description: description, block: block }
  end

  # Parse options from argv, removing recognized options in place.
  # Unrecognized options starting with "-" raise an error message and exit.
  # If -h is given, prints help and exits.
  def parse!(argv)
    remaining = []
    i = 0
    while i < argv.size
      arg = argv[i]
      if arg == "-h"
        print_help
        exit
      elsif opt = find_option(arg)
        if opt[:value_name]
          i += 1
          if i >= argv.size
            puts "missing argument: #{opt[:flag]} #{opt[:value_name]}"
            exit 1
          end
          opt[:block].call(argv[i])
        else
          opt[:block].call
        end
      elsif arg.start_with?("-")
        puts "unknown option: #{arg}"
        print_help
        exit 1
      else
        remaining << arg
      end
      i += 1
    end
    argv.clear
    remaining.each { |a| argv << a }
    argv
  end

  def to_s
    lines = []
    lines << @banner if @banner
    unless @options.empty?
      lines << "Options:"
      @options.each do |opt|
        if opt[:value_name]
          lines << "    #{opt[:flag]} #{opt[:value_name]}    #{opt[:description]}"
        else
          lines << "    #{opt[:flag]}          #{opt[:description]}"
        end
      end
    end
    lines << "    -h          Show help"
    lines.join("\n")
  end

  private

  def find_option(flag)
    i = 0
    while i < @options.size
      return @options[i] if @options[i][:flag] == flag
      i += 1
    end
    nil
  end

  def print_help
    puts to_s
  end
end
