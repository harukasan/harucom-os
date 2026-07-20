# Lumica Entrance Show

The lumica entrance show plays an original song from flash while two
moving head fixtures run a bar-indexed light show. The show script is
[lumica.rb](../rootfs/data/johakyu/lumica.rb), executed by the johakyu
app (see [johakyu.md](johakyu.md)). The song audio itself is not part
of the repository for copyright reasons. This document describes how to
build it and where it lives in flash.

## Song audio

The show streams a [QOA][qoa] file from raw flash through the stream
statement at the top of the show script:

```ruby
stream :song, address: 0x10440000, bytes: 1826184, channel: 6, volume: 15
```

`address` is the XIP address of the flash region below, and `bytes`
must match the exact size of the QOA file.

### Flash region

The song occupies a dedicated flash region between the firmware image
and the IME dictionary:

| Flash offset | Content                              |
|--------------|--------------------------------------|
| `0x000000`   | Firmware (must stay below 0x440000)  |
| `0x440000`   | Song QOA (1.75 MB available)         |
| `0x600000`   | IME dictionary                       |
| `0x800000`   | LittleFS filesystem                  |

The [Rakefile](../Rakefile) guards both edges. The build aborts when
the firmware grows into the song region, and when the QOA grows into
the dictionary.

### Building the QOA

Start from a 16-bit PCM WAV master and pick a sample rate that fits
the region. Stereo QOA costs about 0.81 x samplerate bytes per second,
so the 129 s song fits at 17.5 kHz (about 1.83 MB):

```sh
ffmpeg -i master.wav -ar 17500 -sample_fmt s16 song.wav
ruby scripts/wav2qoa.rb song.wav -o ~/lumica/lumica.qoa
```

The playback engine resamples any source rate to the 50 kHz mixer with
16.16 fixed point phase stepping (see [pwm-audio.md](pwm-audio.md)), so
a lower rate only trades audio bandwidth, not pitch or timing.

### Flashing

`rake` appends the song to the combined UF2 when
`~/lumica/lumica.qoa` exists (override the path with `SONG_QOA=`).
When the file is absent the song UF2 is skipped and the combined image
contains only the firmware and the dictionary.

## Running the show

In the johakyu app, open `/data/johakyu/lumica.rb` and press
Ctrl-Enter to bind the show, then Ctrl-R to start the transport from
bar 0 on cue. For the closing look, delete the underscore from
`_track(:center)` and press Ctrl-Enter, which aims both beams at the
screen center without interrupting the song.

[qoa]: https://qoaformat.org
