# Johakyu

Johakyu is a live coding engine in the style of [TidalCycles][tidal]
and [Strudel][strudel] that drives PWM audio and DMX lighting from one
pattern language. A pattern describes repeating musical or lighting
events as a function of time, and the same query semantics as
[strudel-rb][strudel-rb] let patterns written for Strudel port over
directly. The engine is pure Ruby in
[rootfs/lib/johakyu/](../rootfs/lib/johakyu/), with time arithmetic on
the C-backed Rational class (the mruby-rational and mruby-bigint gems
from the mruby tree). The live coding UI is
[rootfs/app/johakyu.rb](../rootfs/app/johakyu.rb); show-specific
vocabulary belongs in show scripts under /data, not in the library,
and fixture definitions are [Open Fixture Library][ofl] JSON under
[rootfs/data/dmx/fixtures/](../rootfs/data/dmx/fixtures/).

## Ruby API

Module: `Johakyu`

Pattern core:

- [Johakyu.mini](#johakyumatext---pattern)
- [Johakyu::Pattern](#johakyupattern)
- [Johakyu::Signal](#johakyusignal)
- [Johakyu::Clock](#johakyuclock)

Control plane:

- [Control statements](#control-statements)
- [Johakyu::Session](#johakyusession)
- [Johakyu::Live](#johakyulive)
- [Fixtures](#fixtures)

Patterns are built from mini notation or from factory methods, transformed
by chaining, and read back by querying a time span. Time is measured in
cycles: one cycle is the repeating unit, and every query speaks in cycle
positions.

```ruby
require "johakyu/mini"

pattern = Johakyu.mini("bd [sd cp]").fast(2)
haps = pattern.query_arc(0, 1)   # events in the first cycle
```

### Johakyu.mini(text) -> Pattern

Parses mini notation (see below) into a pattern. `Pattern.reify` calls it
automatically wherever a pattern argument accepts a plain string.

### Johakyu::Pattern

A pattern wraps a query function from a `TimeSpan` to an array of `Hap`
events. `query_arc(begin_time, end_time)` queries a span given as numbers.

Each `Hap` carries:

| Field   | Meaning |
|---------|---------|
| `whole` | Full span of the event, or nil for continuous values |
| `part`  | Portion inside the queried span |
| `value` | Event value (String, Numeric, or a `{s:, n:}` Hash) |

`has_onset?` is true when the part starts the whole, which is the test
schedulers use to trigger an event exactly once.

Factories:

| Method | Result |
|--------|--------|
| `Pattern.pure(v)` | `v` once per cycle |
| `Pattern.silence` | no events |
| `Pattern.fastcat(*items)` | items share one cycle |
| `Pattern.slowcat(*items)` | one item per cycle |
| `Pattern.sequence(*items)` | alias of fastcat |
| `Pattern.stack(*items)` | items in parallel |
| `Pattern.euclid(pulses, steps, rotation = 0)` | Euclidean rhythm (Bjorklund) |

Transforms (each returns a new pattern): `fast`, `slow`, `early`, `late`,
`rev`, `every(n) { |p| ... }`, `struct`, `mask`, `euclid`, `segment(n)`,
`range(min, max)`, `degrade_by(amount)`, `degrade`, `onsets_only`,
`with_value { |v| ... }`, `with_control(key, other)`, and the value
arithmetic `add`, `sub`, `mul`, `div`.

### Johakyu::Signal

Continuous signals: `Johakyu.sine`, `cosine`, `saw`, `isaw`, `tri`,
`square_signal`, and `Johakyu.signal { |position| ... }` for a custom
function. A signal is a `Pattern` whose query returns one hap covering the
query span, valued at the span midpoint; it has no whole, so it never
produces onsets. Discretize with `segment(n)` or sample per tick with
`sample(position)`.

### Johakyu::Clock

A free-running master clock mapping `Machine.board_millis` to a cycle
position. `position` returns the current cycle position as a Float, and
`position_to_ms(position)` converts a future position back to a
board_millis deadline. Tempo is set through `bpm=`, `cpm=` (cycles per
minute, Strudel setcpm), or `cps=` (cycles per second, Strudel setcps);
`beats_per_cycle` (default 4) relates bpm to cycle length. A tempo change
rebases the origin so the position stays continuous. There is no
maintenance task and no dependency on the audio engine.

### Control statements

Every statement is a Pattern whose values are control maps (Hash)
carrying the sound key (`:s`) and light keys (fixture personality
attributes plus `:target`). One query drives both sinks; the session
dispatcher splits the map.

```ruby
Johakyu.sound("bd*4").color("<red blue>")   # light rides the kick
Johakyu.pan(Johakyu.sine.slow(8)).on(:s1)   # standalone automation
Johakyu.dimmer("1 0").spread(0.5, on: :all) # chase across members
```

Chaining attaches controls with structure from the left (Tidal's `#`):
`dimmer("1 0").color("<red blue>")` samples the colors at the dimmer's
event times. Use two statements when the structures must stay
independent.

### Johakyu::Session

The dispatcher ([dsl.rb](../rootfs/lib/johakyu/dsl.rb)). Statements are
bound to named tracks; `update` must run every loop iteration.

```ruby
session = Johakyu::Session.new(audio: Board::PWMAudio.new, bpm: 120)
session.load_kit    # /data/drums WAVs, or renders the kit on board
session.bind_statement(:drums, Johakyu.sound("bd*4").color("<red blue>"))
loop do
  session.update
  DMX.keepalive
  sleep_ms 10
end
```

Sound controls become sample-accurate reservations on the C audio
engine; light controls become fixture writes at their target frame
time. `tempo`, `audio_latency_ms=`, and quantized rebinding keep a
running show editable.

### Johakyu::Live

The live coding isolation layer ([live.rb](../rootfs/lib/johakyu/live.rb)).
The johakyu app evaluates the editor buffer in a resident Sandbox task,
which must not touch the running session: the scheduler arrays are
mutated by the app task on every update, and a preemptive task switch
mid-mutation would corrupt them. The script instead talks to a `Live`
recorder through top-level DSL methods (`tempo`, `track`, `_track`,
`sound`, ...) that only build patterns and record intents. When the
sandbox finishes cleanly the app task calls `Live#apply`, which replays
the recording onto the session; if the script raised, the recording is
discarded and the show keeps playing. Each eval describes the whole
desired state: tracks absent from the new recording are removed, so an
empty buffer silences everything. The patch is the exception, kept
unless the script states a new rig.

### Fixtures

The fixture model ([fixture.rb](../rootfs/lib/johakyu/fixture.rb)):
`Personality` maps attribute names to channel offsets, `Patch` assigns
base addresses, `Group` broadcasts with optional value spread. The DMX
universe lives in the C engine; this layer only resolves attributes to
absolute channels and quantizes values, and reads back through
`DMX.get` instead of caching.

Personalities are built from [Open Fixture Library][ofl] JSON
definitions under `/data/dmx/fixtures` (read by the `DMX::Fixture`
loader): channel order gives the offsets, capability types classify
the attributes, and labeled capability bands become the name tables,
valued at the band midpoint. A strobe channel takes its active range
from the widest capability band. There is no built-in rig; the live
script patches it, and later statements in the same eval resolve
against the pending rig, so the fixture lines come first. A script
without fixture statements keeps the current patch.

```ruby
fixture :s1, "shehds_80w_led_spot_light", mode: "13ch", address: 1
fixture :s2, "shehds_80w_led_spot_light", mode: "13ch", address: 14
group :all, :s1, :s2
```

```ruby
Johakyu.dmx(:s1).pan(0.5).tilt(0.2)      # normalized 0.0-1.0, chainable
Johakyu.dmx(:all).dimmer(1.0)            # group broadcast
Johakyu.dmx(:s1).color(:red)             # named wheel positions
Johakyu.dmx(:s1).raw(:pan, 200)          # raw 0-255 escape hatch
```

`Johakyu::UniverseView`
([universe_view.rb](../rootfs/lib/johakyu/universe_view.rb)) renders
the cycle bar, scheduler health, per-fixture readbacks, and the raw
channel grid at the top of the live coding UI. The view sizes itself
from the patch: one readback row per fixture and enough grid rows for
the patched channels (both capped), and without a rig it collapses to
the clock row, so the app doubles as an audio-only sequencer with the
editor taking the rest of the screen. Drawing is differential with a
precomputed value-string table, so the steady-state draw path
allocates nothing.

## Mini notation

`Johakyu.mini` accepts the strudel-rb subset:

| Syntax | Meaning |
|--------|---------|
| `bd ~ sn ~` | sequence with rests (`~` or `-`) |
| `bd*2` | fast: n times per step |
| `bd!3` | replicate: n steps |
| `bd/2` | slow: once per n cycles |
| `[bd hh]` | group: nested sequence in one step |
| `<a b c>` | one item per cycle |
| `bd, hh*4` | parallel stack |
| `bd:2` | sample number, value `{s: "bd", n: 2}` |
| `_` | hold: extends the previous event |

A hand-written recursive descent parser builds an AST of plain hashes, and
the AST compiles through a cycle-indexed interpreter that mirrors
strudel-rb, so hold and replicate keep their exact semantics. Atom values
stay Strings ("bd", "red", "0.5"); consumers decide how to interpret them.

## Architecture

### Query model

A pattern is a pure function: it never stores events, it answers queries.
Querying a span yields haps whose `part` lies inside the span; an event
whose `whole` started earlier still appears, with `has_onset?` false.
Multi-cycle queries are split per cycle first, so factories only reason
about a single cycle.

### Exact rational time

All times are `Rational` values. Onset detection compares
`whole.begin_time == part.begin_time`; floating point would lose onsets at
cycle boundaries, so exactness is correctness, not a nicety. The
`Fraction` module is a thin facade over Ruby core `Rational` adding the
cycle helpers (`sam`, `next_sam`, `cycle_pos`) and a Float conversion that
quantizes onto a 1/3840 grid, which covers halves, thirds, quarters,
fifths, and 16ths exactly. The Rational arithmetic itself runs in C; a
pure Ruby fraction class in this position dominated the board tick cost
through per-operation allocation.

### Scheduling and timing

The scheduler ([scheduler.rb](../rootfs/lib/johakyu/scheduler.rb))
stages tracks in cycle-sized chunks: each track keeps a staged_until
position, and `tick` advances at most one track per call (the most
urgent one), converting every onset in the chunk into a pending event
stamped with its target board_millis. Querying per chunk instead of per
tick keeps the mruby query cost (Fraction and Hap allocation, GC
pressure) off the main loop; a typical tick does no query work at all,
so `pump` fires events with loop-iteration jitter only.

Events fire RESERVE_LEAD_MS early. For sound, the dispatcher converts
the musical target time to a sample offset (board_millis and the audio
engine's sample_clock read as an anchor pair) and reserves the sound in
C through `play_at`/`tone_at`, so playback lands sample accurate
regardless of loop jitter; the lead absorbs staging pauses and GC.
Light writes wait in a small due list and land on their target time
with loop granularity, well inside one 25 ms DMX frame. A fixed
audio_latency_ms offset aligns the two sinks (PWM audio and moving
head response differ by roughly 20 ms).

Live replacement is quantized: rebinding an existing track applies at
the next integer cycle boundary. Events already staged past that
boundary are dropped and restaged from the new pattern, so edits land
musically. A track whose query raises falls back to its last good
pattern instead of silencing the whole scheduler.

### Determinism

`degrade_by` and friends use `Pattern.time_to_rand`, a hash of the event
time (matching strudel-rb), not a global random source. The same query
always returns the same events, which keeps replayed shows and tests
reproducible.

### mruby constraints

Hot query paths use while loops and preallocated arrays; mruby lacks
`flat_map`/`filter_map`, and block-heavy chains are comparatively
expensive on the board. `Signal#sample` folds `fast`/`slow`/`range` into
three Float coefficients for the same reason.

## DAW terminology

For readers coming from DAW or lighting console software:

| Johakyu / Strudel | DAW equivalent |
|-------------------|----------------|
| cycle | one bar of a loop |
| Pattern | a clip, or one step sequencer row |
| Hap | a note or automation event in the clip |
| onset | note-on |
| whole vs part | the note vs the slice visible in the current view |
| `stack` | layered tracks playing together |
| `slowcat`, `<a b>` | a playlist alternating clips per bar |
| `euclid(3, 8)` | Euclidean step sequencer |
| Signal | LFO or automation curve |
| `segment(n)` | sample-and-hold of an LFO into n steps |
| `degrade_by` | per-step trigger probability |
| `cps=`, `cpm=`, `bpm=` | tempo |

## References

- [TidalCycles][tidal]: the original pattern language for live coding
- [Strudel][strudel]: TidalCycles semantics in JavaScript; the mini
  notation reference
- [strudel-rb][strudel-rb]: Ruby port whose query semantics this core
  follows
- [Open Fixture Library][ofl]: the fixture definition format read from
  `/data/dmx/fixtures`
- Godfried Toussaint, "The Euclidean Algorithm Generates Traditional
  Musical Rhythms": the basis of `Pattern.euclid`

[tidal]: https://tidalcycles.org/
[strudel]: https://strudel.cc/
[strudel-rb]: https://github.com/asonas/strudel-rb
[ofl]: https://open-fixture-library.org/
