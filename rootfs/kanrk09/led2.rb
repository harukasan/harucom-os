require "pwm"

pwm = PWM.new(1, frequency: 1000, duty: 0.0)

loop do
  0.upto(100) do |i| # 0 -> 100
    pwm.duty((i ** 2) / 100.0)
    sleep 0.015
  end
  100.downto(0) do |i| # 100 -> 0
    pwm.duty((i ** 2) / 100.0)
    sleep 0.015
  end
end
