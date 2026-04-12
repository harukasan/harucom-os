module PicoRabbit
  class Presenter
    def initialize(slides:, renderer:, keyboard:, timer: nil)
      @slides = slides
      @renderer = renderer
      @keyboard = keyboard
      @current = 0
      @step = 0
      @timer = timer
    end

    def start
      render_current
      while true
        key = @keyboard.read_char
        if key
          case key
          when Keyboard::ESCAPE, Keyboard::CTRL_Q
            break
          when Keyboard::UP
            @timer.jump if @timer
          when Keyboard::RIGHT, Keyboard::PAGEDOWN, Keyboard::ENTER, " "
            advance
          when Keyboard::LEFT, Keyboard::PAGEUP, Keyboard::BSPACE
            retreat
          when Keyboard::HOME
            go_to(0)
          when Keyboard::END_KEY
            go_to(@slides.length - 1)
          end
        end
        render_current if @timer
        DVI::Graphics.commit
      end
    end

    private

    def render_current
      @renderer.render(@slides[@current], @current, @slides.length, @step)
    end

    def wait_count(slide)
      n = 0
      slide.elements.each { |e| n += 1 if e.type == :wait }
      n
    end

    def advance
      max = wait_count(@slides[@current])
      if @step < max
        @step += 1
        render_current
      elsif @current < @slides.length - 1
        @current += 1
        @step = 0
        render_current
      end
    end

    def retreat
      if @step > 0
        @step -= 1
        render_current
      elsif @current > 0
        @current -= 1
        @step = wait_count(@slides[@current])
        render_current
      end
    end

    def go_to(index)
      if index >= 0 && index < @slides.length
        @current = index
        @step = 0
        render_current
      end
    end
  end
end
