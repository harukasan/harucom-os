module PicoRabbit
  class Element
    attr_reader :type, :text, :level

    def initialize(type, text = nil, level = 0)
      @type = type
      @text = text
      @level = level
    end
  end

  class Slide
    attr_reader :title, :elements

    def initialize(title, elements)
      @title = title
      @elements = elements
    end
  end
end
