module PicoRabbit
  class Presenter
    def initialize(slides:, renderer:, keyboard:)
      @slides = slides
      @renderer = renderer
      @keyboard = keyboard
      @current = 0
    end

    def start
      render_current
      loop do
        key = @keyboard.read_char
        if key
          case key
          when Keyboard::ESCAPE, Keyboard::CTRL_Q
            break
          when Keyboard::RIGHT, Keyboard::PAGEDOWN, Keyboard::ENTER, " "
            next_slide
          when Keyboard::LEFT, Keyboard::PAGEUP, Keyboard::BSPACE
            prev_slide
          when Keyboard::HOME
            go_to(0)
          when Keyboard::END_KEY
            go_to(@slides.length - 1)
          end
        end
        DVI::Graphics.commit
      end
    end

    private

    def render_current
      @renderer.render(@slides[@current], @current, @slides.length)
    end

    def next_slide
      if @current < @slides.length - 1
        @current += 1
        render_current
      end
    end

    def prev_slide
      if @current > 0
        @current -= 1
        render_current
      end
    end

    def go_to(index)
      if index != @current && index >= 0 && index < @slides.length
        @current = index
        render_current
      end
    end
  end
end
