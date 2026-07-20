require "gpio"

led = GPIO.new(1, GPIO::OUT)
loop do
  led.write 1
  sleep 0.5
  led.write 0
  sleep 0.5
end
