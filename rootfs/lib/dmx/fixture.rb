# DMX::Fixture, a loader for fixture definitions in the Open Fixture
# Library JSON format.
#
# Only a tolerant subset is read: name, availableChannels (with
# fineChannelAliases, defaultValue and capability dmxRanges) and modes.
# Unknown keys are ignored, so definitions downloaded from
# open-fixture-library.org work unless they rely on matrix template
# channels.
#
#   fixture = DMX::Fixture.read("/data/dmx/fixtures/some_light.json")
#   fixture[:name]              # => "Some Light"
#   mode = fixture[:modes][0]
#   mode[:label]                # => "13ch"
#   mode[:channels][5][:name]   # => "Dimmer"
#   mode[:channels][6][:caps]   # => [[0, 15, "Open"], [16, 251, ...]]
#
# Mode channels are ordered as on the wire, so the DMX channel of entry
# i is the fixture base address plus i. Fine channel aliases appear as
# channels of their own with no capabilities. Each channel entry is
# {name:, default:, caps:}; name is nil for unused (null) slots.

module DMX
  module Fixture
    # List fixture definition files in a directory, sorted.
    def self.list(dir)
      paths = []
      return paths unless Dir.exist?(dir)
      Dir.open(dir) do |d|
        while entry = d.read
          next if entry == "." || entry == ".."
          paths << "#{dir}/#{entry}" if entry.end_with?(".json")
        end
      end
      paths.sort
    end

    # Read and parse a fixture file. Returns nil when the file is
    # missing or unusable. A fixture without a name is named after the
    # file.
    def self.read(path)
      return nil unless File.exist?(path)
      text = File.open(path, "r") { |f| f.read }
      return nil unless text
      fixture = parse(text)
      return nil unless fixture
      fixture[:name] = path.split("/").last unless fixture[:name]
      fixture
    end

    # Parse fixture JSON text into {name:, modes:}, or nil when the
    # document lacks the required sections.
    def self.parse(text)
      begin
        data = JSON.parse(text)
      rescue
        return nil
      end
      return nil unless data.is_a?(Hash)
      available = data["availableChannels"]
      modes = data["modes"]
      return nil unless available.is_a?(Hash) && modes.is_a?(Array)

      fine = fine_aliases(available)
      parsed = []
      mi = 0
      while mi < modes.length
        mode = modes[mi]
        mi += 1
        next unless mode.is_a?(Hash) && mode["channels"].is_a?(Array)
        channels = mode_channels(mode["channels"], available, fine)
        next if channels.empty?
        label = mode["shortName"] || mode["name"] || "mode #{parsed.length + 1}"
        parsed << { label: label, channels: channels }
      end
      return nil if parsed.empty?

      name = data["name"]
      { name: name.is_a?(String) ? name : nil, modes: parsed }
    end

    # Fine channel aliases appear in mode lists but are defined on
    # their coarse parent; they carry no capabilities of their own.
    def self.fine_aliases(available)
      fine = {}
      available.each do |key, defn|
        next unless defn.is_a?(Hash)
        aliases = defn["fineChannelAliases"]
        next unless aliases.is_a?(Array)
        i = 0
        while i < aliases.length
          fine[aliases[i]] = key
          i += 1
        end
      end
      fine
    end

    def self.mode_channels(list, available, fine)
      channels = []
      i = 0
      while i < list.length
        key = list[i]
        i += 1
        defn = key ? available[key] : nil
        defn = nil unless defn.is_a?(Hash)
        defn = nil if key && fine[key]
        channels << {
          name: key,
          default: default_value(defn),
          caps: capabilities(defn),
        }
      end
      channels
    end

    def self.default_value(defn)
      return 0 unless defn.is_a?(Hash)
      value = defn["defaultValue"]
      return 0 unless value.is_a?(Integer)
      return 0 if value < 0
      return 255 if 255 < value
      value
    end

    # Normalize capability/capabilities into [[min, max, label], ...].
    def self.capabilities(defn)
      return [] unless defn.is_a?(Hash)
      list = defn["capabilities"]
      list = [defn["capability"]] unless list.is_a?(Array)
      caps = []
      i = 0
      while i < list.length
        cap = list[i]
        i += 1
        next unless cap.is_a?(Hash)
        range = cap["dmxRange"]
        if range.is_a?(Array) && range[0].is_a?(Integer) && range[1].is_a?(Integer)
          caps << [range[0], range[1], capability_label(cap)]
        else
          caps << [0, 255, capability_label(cap)]
        end
      end
      caps
    end

    # A display label like the one a lighting console would show:
    # the comment, or the shutter effect with its speed span, or the
    # capability type.
    def self.capability_label(cap)
      comment = cap["comment"]
      return comment if comment.is_a?(String) && !comment.empty?
      effect = cap["shutterEffect"]
      if effect.is_a?(String)
        if cap["speedStart"].is_a?(String) && cap["speedEnd"].is_a?(String)
          return "#{effect} #{cap["speedStart"]}..#{cap["speedEnd"]}"
        end
        return effect
      end
      type = cap["type"]
      type.is_a?(String) ? type : ""
    end
  end
end
