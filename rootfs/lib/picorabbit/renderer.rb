module PicoRabbit
  class Renderer
    def initialize(p5, theme, timer: nil, metadata: {})
      @p5 = p5
      @theme = theme
      @timer = timer
      @metadata = metadata
    end

    def render(slide, slide_index, total_slides, step)
      @theme.render_slide(@p5, slide, slide_index, total_slides, step, @metadata)
      @timer.render(@p5, slide_index, @theme.margin_x) if @timer
      @p5.commit
    end
  end
end
