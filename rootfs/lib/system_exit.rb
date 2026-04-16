# SystemExit: Exception raised by Kernel#exit
#
# Inherits from Exception (not StandardError) so that `rescue => e`
# does not catch it, matching CRuby behavior.

class SystemExit < Exception
  attr_reader :status

  def initialize(status = 0)
    @status = status
    super("exit")
  end

  def success?
    @status == 0
  end
end

module Kernel
  def exit(status = 0)
    raise SystemExit.new(status)
  end
end
