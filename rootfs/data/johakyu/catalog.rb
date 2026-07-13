# Jo-ha-kyu catalog: the show vocabulary for the johakyu app. The
# names jo/ha/kyu live only in this /data/johakyu module; the library
# under /lib stays generic (research 08). Scene files require this
# file; the top-level definitions are global, so one require serves
# every later buffer eval.
#
# Usage in the editor buffer (a catalog call is one statement, so it
# records like sound()/pan(); inside track blocks it returns the
# pattern):
#
#   track(:beat) { jo("kick4") }
#   ha("circle", on: :s1, slow: 8)
#   kyu("finale")
#
# 序 jo: basic forms, playable alone. 破 ha: developments combining
# forms. 急 kyu: the big moves for the climax.

# -- 序: sound forms (mini notation) --
JOHAKYU_JO_SOUND = {
  "heartbeat" => "bd ~ ~ bd ~ ~ ~ ~",
  "kick2" => "bd ~ bd ~",
  "kick4" => "bd*4",
  "backbeat" => "bd ~ sd ~",
  "snare24" => "~ sd ~ sd",
  "hats8" => "hh*8",
  "offbeat" => "~ hh ~ hh",
}

# -- 序: light forms (lambdas of opts; each handles its own target) --
JOHAKYU_JO_LIGHT = {
  "home" => lambda { |o|
    Johakyu::Pattern.stack(Johakyu.pan(0.5), Johakyu.tilt(0.4),
                           Johakyu.color("white")).on(o[:on] || :all)
  },
  "pan_lr" => lambda { |o|
    Johakyu.pan(Johakyu.sine.slow(o[:slow] || 8)).on(o[:on] || :all)
  },
  "tilt_ud" => lambda { |o|
    Johakyu.tilt(Johakyu.sine.range(0.2, 0.6).slow(o[:slow] || 8)).on(o[:on] || :all)
  },
  "dimmer_wave" => lambda { |o|
    Johakyu.dimmer(Johakyu.sine.slow(o[:slow] || 4)).on(o[:on] || :all)
  },
  "dimmer_beat" => lambda { |o|
    Johakyu.dimmer(o[:steps] || "1 0 1 0").on(o[:on] || :all)
  },
  "color_cycle" => lambda { |o|
    Johakyu.color(o[:colors] || "<white red blue yellow>").on(o[:on] || :all)
  },
  "gobo_cycle" => lambda { |o|
    Johakyu.gobo("<open gobo1 gobo3 gobo5>").on(o[:on] || :all)
  },
  "gobo_shake" => lambda { |o|
    Johakyu.gobo("gobo3_shake").on(o[:on] || :all)
  },
  "strobe" => lambda { |o|
    Johakyu.strobe(o[:rate] || 0.6).on(o[:on] || :all)
  },
  "focus_sweep" => lambda { |o|
    Johakyu.focus(Johakyu.saw.slow(o[:slow] || 8)).on(o[:on] || :all)
  },
  "prism" => lambda { |o|
    Johakyu.prism(1.0).on(o[:on] || :all)
  },
}

# -- 破: developments --
JOHAKYU_HA = {
  # Circle around a point: pan follows cosine while tilt follows sine.
  "circle" => lambda { |o|
    slow = o[:slow] || 8
    pan_center = o[:pan] || 0.5
    tilt_center = o[:tilt] || 0.4
    radius = o[:radius] || 0.15
    Johakyu::Pattern.stack(
      Johakyu.pan(Johakyu.cosine.range(pan_center - radius, pan_center + radius).slow(slow)),
      Johakyu.tilt(Johakyu.sine.range(tilt_center - radius, tilt_center + radius).slow(slow))
    ).on(o[:on] || :all)
  },
  # Figure eight: tilt runs twice per pan sweep.
  "figure8" => lambda { |o|
    slow = o[:slow] || 8
    radius = o[:radius] || 0.15
    Johakyu::Pattern.stack(
      Johakyu.pan(Johakyu.cosine.range(0.5 - radius, 0.5 + radius).slow(slow)),
      Johakyu.tilt(Johakyu.sine.range(0.4 - radius, 0.4 + radius).slow(slow).fast(2))
    ).on(o[:on] || :all)
  },
  # The same sweep on every member, phase-offset so they mirror.
  "mirror" => lambda { |o|
    Johakyu.pan(Johakyu.sine.range(0.3, 0.7).slow(o[:slow] || 8))
           .spread(0.5, on: o[:on] || :all)
  },
  # One-hot dimmer chase across the members.
  "chase" => lambda { |o|
    Johakyu.dimmer("1 0 0 0").fast(o[:fast] || 1)
           .spread(o[:amount] || 0.5, on: o[:on] || :all)
  },
  # Dimmer beat carrying a color change on each hit.
  "color_beat" => lambda { |o|
    Johakyu.dimmer(o[:steps] || "1 0 1 0")
           .color(o[:colors] || "<red blue>")
           .on(o[:on] || :all)
  },
}

# -- 急: the big moves --
JOHAKYU_KYU = {
  "strobe_burst" => lambda { |o|
    Johakyu.strobe("1 ~ 1 1 ~ 1 ~ 1").fast(o[:fast] || 2).on(o[:on] || :all)
  },
  "spin" => lambda { |o|
    JOHAKYU_HA["circle"].call(on: o[:on] || :all, slow: o[:slow] || 2,
                              radius: o[:radius] || 0.2)
  },
  "finale" => lambda { |o|
    Johakyu::Pattern.stack(
      Johakyu.dimmer("1"),
      Johakyu.strobe(0.7),
      Johakyu.color("<red white>")
    ).on(o[:on] || :all)
  },
}

# Catalog dispatch: builds the pattern and records it as a statement
# (or returns it inside a track block), exactly like the sound()/pan()
# sugar.
def johakyu_catalog(table, kind, name, opts)
  entry = table[name.to_s]
  raise ArgumentError, "unknown #{kind} form: #{name}" unless entry
  pattern = entry.is_a?(String) ? Johakyu.sound(entry) : entry.call(opts)
  $johakyu_live.capturing? ? pattern : $johakyu_live.record_bare(pattern)
end

def jo(name, opts = {})
  if JOHAKYU_JO_SOUND[name.to_s]
    johakyu_catalog(JOHAKYU_JO_SOUND, "jo", name, opts)
  else
    johakyu_catalog(JOHAKYU_JO_LIGHT, "jo", name, opts)
  end
end

def ha(name, opts = {})
  johakyu_catalog(JOHAKYU_HA, "ha", name, opts)
end

def kyu(name, opts = {})
  johakyu_catalog(JOHAKYU_KYU, "kyu", name, opts)
end
