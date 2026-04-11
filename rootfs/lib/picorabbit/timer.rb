module PicoRabbit
  class Timer
    TRACK_Y = 456
    TRACK_HEIGHT = 2
    SPRITE_OFFSET_Y = -22
    GRAVITY = 0.7
    JUMP_POWER = -7.6

    def initialize(allotted_time, total_slides, track_color: 0x49)
      @allotted_ms = allotted_time * 60 * 1000
      @total_slides = total_slides
      @track_color = track_color
      @start_ms = Machine.board_millis
      @usagi = BMP.load("/data/usagi.bmp")
      @kame = BMP.load("/data/kame.bmp")
      @usagi_vy = 0.0
      @usagi_jump_y = 0.0
    end

    def jump
      @usagi_vy = JUMP_POWER if @usagi_jump_y == 0.0
    end

    def render(p5, slide_index, margin_x)
      track_left = margin_x
      track_right = 640 - margin_x
      track_width = track_right - track_left - @usagi.width

      # Track line
      p5.fill(@track_color)
      p5.no_stroke
      p5.rect(track_left, TRACK_Y, track_right - track_left, TRACK_HEIGHT)
      p5.no_fill

      # Turtle position = slide progress
      if @total_slides > 1
        turtle_progress = slide_index.to_f / (@total_slides - 1)
      else
        turtle_progress = 0.0
      end
      turtle_x = track_left + (turtle_progress * track_width).to_i

      # Rabbit position = time progress
      elapsed = Machine.board_millis - @start_ms
      rabbit_progress = elapsed.to_f / @allotted_ms
      rabbit_progress = 1.0 if rabbit_progress > 1.0
      rabbit_x = track_left + (rabbit_progress * track_width).to_i

      # Jump physics
      @usagi_jump_y += @usagi_vy
      @usagi_vy += GRAVITY
      if @usagi_jump_y >= 0.0
        @usagi_jump_y = 0.0
        @usagi_vy = 0.0
      end

      rabbit_y = TRACK_Y + SPRITE_OFFSET_Y + @usagi_jump_y.to_i

      p5.image_masked(@kame.data, @kame.mask, turtle_x, TRACK_Y + SPRITE_OFFSET_Y, @kame.width, @kame.height)
      p5.image_masked(@usagi.data, @usagi.mask, rabbit_x, rabbit_y, @usagi.width, @usagi.height)
    end
  end
end
