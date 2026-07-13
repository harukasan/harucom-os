# Johakyu Pattern Core

Johakyu is a live coding pattern engine in the style of [TidalCycles][tidal]
and [Strudel][strudel]. A pattern describes repeating musical or lighting
events as a function of time, and the same query semantics as
[strudel-rb][strudel-rb] let patterns written for Strudel port over
directly. The core is pure Ruby in [rootfs/lib/johakyu/](../rootfs/lib/johakyu/),
with time arithmetic on the C-backed Rational class (the mruby-rational
and mruby-bigint gems from the mruby tree).

## Ruby API

Module: `Johakyu`

- [Johakyu.mini](#johakyumatext---pattern)
- [Johakyu::Pattern](#johakyupattern)
- [Johakyu::Signal](#johakyusignal)
- [Johakyu::Clock](#johakyuclock)

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
- Godfried Toussaint, "The Euclidean Algorithm Generates Traditional
  Musical Rhythms": the basis of `Pattern.euclid`

[tidal]: https://tidalcycles.org/
[strudel]: https://strudel.cc/
[strudel-rb]: https://github.com/asonas/strudel-rb
