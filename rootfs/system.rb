# Harucom OS system entry point
#
# Starts background services and loads the main application.

# USB host background task
Task.new(name: "usb_host") do
  loop do
    USB::Host.task
    Task.pass
  end
end

require "dvi_test"
