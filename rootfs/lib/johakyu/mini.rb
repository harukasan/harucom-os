# Johakyu mini notation parser, compatible with strudel-rb's subset.
#
#   Mini.parse("bd ~ sn ~")      sequence with rests
#   "bd*2"                       fast (n times per step)
#   "bd!3"                       replicate (n steps)
#   "bd/2"                       slow (once per n cycles)
#   "[bd hh]"                    group (nested sequence in one step)
#   "<a b c>"                    one item per cycle (slowcat)
#   "bd, hh*4"                   parallel stack
#   "bd:2"                       sample number, value {s: "bd", n: 2}
#   "~" or "-"                   rest
#   "_"                          hold (extends the previous event)
#
# A hand-written recursive descent parser builds an AST of plain
# hashes, and the AST compiles to a function from cycle index to an
# event list (start, end, value with Fraction positions), mirroring
# strudel-rb's interpreter so hold and replicate keep their exact
# semantics. Atom values stay Strings ("bd", "red", "0.5"); consumers
# decide how to interpret them.

require "johakyu/pattern"

module Johakyu
  module Mini
    ZERO = Fraction.new(0)
    ONE = Fraction.new(1)

    def self.parse(input)
      # Parse memo: live evals rebuild every track, so unchanged
      # pattern strings dominate. Patterns are pure (the cycle memo
      # below caches results of a pure function), so sharing one
      # instance across tracks and evals is safe.
      @parsed ||= {}
      cached = @parsed[input]
      return cached if cached
      ast = Reader.new(input).read_pattern
      events_fn = Compiler.compile(ast)
      # One-entry memo: staging queries walk cycles sequentially, and
      # half-cycle chunks hit the same cycle twice, so remembering the
      # last cycle's event list halves the interpreter work.
      memo_cycle = nil
      memo_events = nil
      @parsed[input] = Pattern.new do |span|
        spans = span.span_cycles
        haps = []
        i = 0
        while i < spans.length
          sub = spans[i]
          i += 1
          cycle_start = sub.begin_time.sam
          cycle_index = cycle_start.floor_i
          if memo_cycle == cycle_index
            events = memo_events
          else
            events = events_fn.call(cycle_index)
            memo_cycle = cycle_index
            memo_events = events
          end
          j = 0
          while j < events.length
            event = events[j]
            j += 1
            whole = TimeSpan.new(cycle_start + event[0], cycle_start + event[1])
            part = whole.intersection(sub)
            haps << Hap.new(whole, part, event[2]) if part
          end
        end
        haps
      end
    end

    # Tokenizer and recursive descent parser. Produces the same AST
    # shapes as strudel-rb's transform: String atoms, nil rests,
    # :_elongate, {s:, n:} sampled atoms, and {sequence:/stack:/
    # slowcat:, mult:/div:/rep:} nodes.
    class Reader
      def initialize(input)
        @input = input
        @pos = 0
        @length = input.length
      end

      def read_pattern
        sequences = [read_sequence]
        skip_spaces
        while peek == ","
          @pos += 1
          sequences << read_sequence
          skip_spaces
        end
        unless @pos >= @length
          raise ArgumentError, "mini notation: unexpected '#{peek}' at #{@pos}"
        end
        return sequences[0] if sequences.length == 1
        { stack: sequences }
      end

      def read_sequence(closers = nil)
        elements = []
        loop do
          skip_spaces
          ch = peek
          break if ch.nil? || ch == "," || (closers && closers.include?(ch))
          elements << read_element
        end
        raise ArgumentError, "mini notation: empty sequence" if elements.empty?
        return elements[0] if elements.length == 1
        { sequence: elements }
      end

      private

      def read_element
        ch = peek
        node = nil
        if ch == "["
          @pos += 1
          node = read_group_body
        elsif ch == "<"
          @pos += 1
          inner = read_sequence(">")
          expect(">")
          items = inner.is_a?(Hash) && inner[:sequence] ? inner[:sequence] : [inner]
          node = { slowcat: items }
        elsif ch == "~" || ch == "-"
          @pos += 1
          node = nil
        else
          node = read_atom
        end
        read_modifier(node)
      end

      # Inside [...] a comma builds a stack, like the top level.
      def read_group_body
        sequences = [read_sequence("],")]
        skip_spaces
        while peek == ","
          @pos += 1
          sequences << read_sequence("],")
          skip_spaces
        end
        expect("]")
        return sequences[0] if sequences.length == 1
        { stack: sequences }
      end

      def read_atom
        start = @pos
        while @pos < @length && atom_char?(@input[@pos])
          @pos += 1
        end
        if @pos == start
          raise ArgumentError, "mini notation: unexpected '#{peek}' at #{@pos}"
        end
        name = @input[start, @pos - start]
        return :_elongate if name == "_"
        if peek == ":"
          @pos += 1
          return { s: name, n: read_integer }
        end
        name
      end

      def read_modifier(node)
        ch = peek
        if ch == "*"
          @pos += 1
          wrap_modifier(node, :mult, read_integer)
        elsif ch == "/"
          @pos += 1
          wrap_modifier(node, :div, read_integer)
        elsif ch == "!"
          @pos += 1
          wrap_modifier(node, :rep, read_integer)
        else
          node
        end
      end

      def wrap_modifier(node, key, value)
        if node.is_a?(Hash) && (node[:sequence] || node[:stack] || node[:slowcat] || node[:s])
          node = node.dup
          node[key] = value
          node
        else
          # Atom, rest, or elongate: wrap so the modifier has a place.
          { atom: node, key => value }
        end
      end

      def read_number
        start = @pos
        while @pos < @length && number_char?(@input[@pos])
          @pos += 1
        end
        if @pos == start
          raise ArgumentError, "mini notation: number expected at #{@pos}"
        end
        @input[start, @pos - start].to_f
      end

      # The interpreter only supports whole-number rates, replicates,
      # and sample numbers; truncating silently played subtly wrong
      # timing, so a fractional value is a loud parse error instead.
      def read_integer
        value = read_number
        int = value.to_i
        if value != int
          raise ArgumentError, "mini notation: whole number expected at #{@pos}"
        end
        int
      end

      def atom_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") ||
          (ch >= "0" && ch <= "9") || ch == "_" || ch == "#" || ch == "."
      end

      def number_char?(ch)
        (ch >= "0" && ch <= "9") || ch == "."
      end

      def skip_spaces
        while @pos < @length && @input[@pos] == " "
          @pos += 1
        end
      end

      def peek
        @pos < @length ? @input[@pos] : nil
      end

      def expect(ch)
        unless peek == ch
          raise ArgumentError, "mini notation: '#{ch}' expected at #{@pos}"
        end
        @pos += 1
      end
    end

    # Compiles an AST node into a function: cycle index (Integer) ->
    # array of [start Fraction, end Fraction, value] events within that
    # cycle. Ported from strudel-rb's events-function interpreter.
    module Compiler
      def self.compile(ast)
        if ast.nil?
          lambda { |_cycle| [] }
        elsif ast == :_elongate
          lambda { |_cycle| [] }
        elsif ast.is_a?(String)
          lambda { |_cycle| [[ZERO, ONE, ast]] }
        elsif ast.is_a?(Hash)
          compile_hash(ast)
        else
          value = ast.to_s
          lambda { |_cycle| [[ZERO, ONE, value]] }
        end
      end

      def self.compile_hash(ast)
        if ast[:rep]
          # Replicated single element becomes an n-step sequence.
          repeat = ast[:rep].to_i
          repeat = 1 if repeat <= 0
          base = strip(ast, :rep)
          items = []
          i = 0
          while i < repeat
            items << base
            i += 1
          end
          return compile({ sequence: items })
        end

        if ast[:s]
          value = { s: ast[:s], n: ast[:n] }
          fn = lambda { |_cycle| [[ZERO, ONE, value]] }
          return with_rate(fn, ast)
        end

        if ast[:atom]
          return with_rate(compile(ast[:atom]), ast)
        end

        if ast[:sequence]
          steps = expand_replicates(ast[:sequence])
          return with_rate(sequence_fn(steps), ast)
        end

        if ast[:stack]
          items = ast[:stack]
          fns = []
          i = 0
          while i < items.length
            fns << compile(items[i])
            i += 1
          end
          fn = lambda do |cycle|
            events = []
            k = 0
            while k < fns.length
              events.concat(fns[k].call(cycle))
              k += 1
            end
            events
          end
          return with_rate(fn, ast)
        end

        if ast[:slowcat]
          items = ast[:slowcat]
          fns = []
          i = 0
          while i < items.length
            fns << compile(items[i])
            i += 1
          end
          n = fns.length
          # "_" inside <...> repeats the previous cycle's item.
          fn = nil
          fn = lambda do |cycle, guard = n|
            if n <= 0 || guard <= 0
              []
            else
              index = cycle % n
              if items[index] == :_elongate
                fn.call(cycle - 1, guard - 1)
              else
                fns[index].call(cycle)
              end
            end
          end
          return with_rate(fn, ast)
        end

        lambda { |_cycle| [] }
      end

      def self.strip(hash, key)
        copy = {}
        hash.each do |k, v|
          copy[k] = v unless k == key
        end
        copy
      end

      def self.expand_replicates(items)
        steps = []
        i = 0
        while i < items.length
          item = items[i]
          i += 1
          if item.is_a?(Hash) && item[:rep]
            repeat = item[:rep].to_i
            repeat = 1 if repeat <= 0
            base = strip(item, :rep)
            j = 0
            while j < repeat
              steps << base
              j += 1
            end
          else
            steps << item
          end
        end
        steps
      end

      def self.sequence_fn(steps)
        # Elongates fold into step weights (strudel semantics: "_"
        # gives the previous step another slot of time), so a group
        # step stretches as a whole instead of only its last event.
        fns = []
        weights = []
        i = 0
        while i < steps.length
          if steps[i] == :_elongate && weights.length > 0
            weights[weights.length - 1] += 1
          else
            # A leading elongate has nothing to extend; it holds a
            # slot of silence like a rest, matching the old layout.
            fns << compile(steps[i] == :_elongate ? nil : steps[i])
            weights << 1
          end
          i += 1
        end
        total = 0
        starts = []
        i = 0
        while i < weights.length
          starts << total
          total += weights[i]
          i += 1
        end
        total = 1 if total <= 0
        lambda do |cycle|
          events = []
          i = 0
          while i < fns.length
            step_start = Fraction.new(starts[i], total)
            weight = weights[i]
            inner = fns[i].call(cycle)
            j = 0
            while j < inner.length
              event = inner[j]
              j += 1
              events << [step_start + event[0] * weight / total,
                         step_start + event[1] * weight / total,
                         event[2]]
            end
            i += 1
          end
          events
        end
      end

      def self.with_rate(fn, ast)
        fn = fast_fn(fn, ast[:mult].to_i) if ast[:mult]
        fn = slow_fn(fn, ast[:div].to_i) if ast[:div]
        fn
      end

      # fast: one output cycle compresses m source cycles.
      def self.fast_fn(events_fn, m)
        m = 1 if m <= 0
        return events_fn if m == 1
        lambda do |cycle|
          events = []
          i = 0
          while i < m
            base = events_fn.call(cycle * m + i)
            j = 0
            while j < base.length
              event = base[j]
              j += 1
              events << [(event[0] + i) / m, (event[1] + i) / m, event[2]]
            end
            i += 1
          end
          events
        end
      end

      # slow: one source cycle stretches across d output cycles. Events
      # keep their full stretched whole; only overlap decides emission.
      def self.slow_fn(events_fn, d)
        d = 1 if d <= 0
        return events_fn if d == 1
        lambda do |cycle|
          base_cycle = cycle >= 0 ? cycle / d : -((-cycle + d - 1) / d)
          portion = cycle - base_cycle * d
          events = []
          base = events_fn.call(base_cycle)
          j = 0
          while j < base.length
            event = base[j]
            j += 1
            start = event[0] * d - portion
            finish = event[1] * d - portion
            next if finish <= ZERO || start >= ONE
            events << [start, finish, event[2]]
          end
          events
        end
      end
    end
  end

  # With the parser available, strings become mini notation wherever a
  # pattern is expected, matching strudel-rb's reify.
  class Pattern
    def self.reify(value)
      return value if value.is_a?(Pattern)
      return Mini.parse(value) if value.is_a?(String) && value.length > 0
      pure(value)
    end
  end

  # Module-level shorthand for building a pattern from mini notation
  # outside a reify position, so transforms can chain on the text:
  # Johakyu.mini("1 0").fast(2).
  def self.mini(text)
    Mini.parse(text)
  end
end
