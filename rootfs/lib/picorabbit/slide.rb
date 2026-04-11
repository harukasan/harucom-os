module PicoRabbit
  class Element
    attr_reader :type, :text, :level
    attr_accessor :align

    def initialize(type, text = nil, level = 0)
      @type = type
      @text = text
      @level = level
      @align = nil
    end
  end

  class Slide
    attr_reader :title, :elements
    attr_accessor :title_slide

    def initialize(title, elements)
      @title = title
      @elements = elements
      @title_slide = false
    end
  end
end
