module PicoRabbit
  class Renderer
    def initialize(p5, theme)
      @p5 = p5
      @theme = theme
    end

    def render(slide, slide_index, total_slides)
      @theme.render_slide(@p5, slide, slide_index, total_slides)
      @p5.commit
    end
  end
end
