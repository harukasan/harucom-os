#!/usr/bin/env python3
"""
Analyze a real-board audio recording of the Harucom OS PWM synth.

    python3 scripts/analyze_recording.py recording.wav [--note-hz 440] [--start 0.5] [--dur 4]

Decodes any ffmpeg-readable file (wav/m4a/mp3/flac) to mono float and reports:

  1. Periodic pop / underrun detection. A ring-buffer underrun on the board
     freezes the PWM level for a stretch, then jumps when the Ruby loop refills.
     That shows up as (a) short dropouts in the short-time RMS envelope and
     (b) spikes in the sample-to-sample difference. We report how many pops we
     found, their median interval in ms, and the implied rate in Hz. A constant
     interval points at a periodic stall (e.g. stop-the-world GC) starving the
     46 ms ring, not at the waveform.

  2. Spectral purity of a clean segment (between pops): the fundamental, the
     harmonic energy, and the non-harmonic ("aliasing/noise") energy relative to
     the fundamental in dB. This tells whether PolyBLEP is actually working on
     the board (expect roughly -35..-40 dB non-harmonic for square; naive is
     ~-15..-20 dB; a pure sine should be very low).

No scipy needed (numpy only). ffmpeg/ffprobe must be on PATH.
"""
import argparse
import subprocess
import sys
import numpy as np


def decode(path):
    """Decode `path` to (samples float32 mono, sample_rate) via ffmpeg."""
    try:
        rate = subprocess.check_output(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=sample_rate", "-of", "csv=p=0", path],
            text=True).strip()
        rate = int(rate)
    except Exception as e:
        sys.exit(f"ffprobe failed on {path}: {e}")
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-map", "a:0", "-ac", "1",
         "-f", "f32le", "-ar", str(rate), "-"],
        stdout=subprocess.PIPE, check=True).stdout
    x = np.frombuffer(raw, dtype="<f4").astype(np.float64)
    return x, rate


def find_pops(x, fs):
    """Detect periodic dropouts/pops via the short-time RMS envelope.

    A square's own edges swamp a sample-difference detector, so instead we track
    the loudness envelope: an underrun briefly drops the level (after AC coupling
    a frozen PWM level decays toward zero), making a dip in the RMS envelope.
    We find dips below a local median, cluster them into events, and also run an
    autocorrelation of the (inverted) envelope to recover the dominant period
    robustly even when individual dips are shallow.

    Returns (pop_times_sec, median_interval_ms, rate_hz, dropout_frac,
             intervals_ms, acf_period_ms).
    """
    hop = max(1, int(fs * 0.001))          # 1 ms envelope hop
    pad = (-len(x)) % hop
    xr = np.concatenate([x, np.zeros(pad)])
    rms = np.sqrt((xr.reshape(-1, hop) ** 2).mean(axis=1) + 1e-20)
    # Local median envelope over ~60 ms to normalize slow level changes.
    k = max(3, int(0.060 * fs / hop) | 1)
    loc = np.array([np.median(rms[max(0, i - k):i + k + 1]) for i in range(len(rms))])
    norm = rms / (loc + 1e-20)
    dropout_frac = float((norm < 0.5).mean())
    # Dip events: envelope falls below half the local level.
    dips = norm < 0.5
    pops = []
    i = 0
    while i < len(dips):
        if dips[i]:
            j = i
            while j < len(dips) and dips[j]:
                j += 1
            pops.append((i + j) // 2 * hop)
            i = j
        else:
            i += 1
    pops = np.array(pops)
    intervals = (np.diff(pops) / fs * 1000.0) if len(pops) >= 2 else np.array([])
    med_int = float(np.median(intervals)) if len(intervals) else 0.0
    rate = 1000.0 / med_int if med_int > 0 else 0.0
    # Autocorrelation of the dip strength (period estimate independent of count).
    acf_period_ms = 0.0
    dip_raw = np.clip(1.0 - norm, 0, None)
    # Only trust an autocorrelation period if there is real dropout depth
    # (otherwise a clean tone's tiny envelope noise yields a spurious peak).
    if dip_raw.max() > 0.4 and dropout_frac > 0.005:
        dip = dip_raw - dip_raw.mean()
        acf = np.correlate(dip, dip, mode="full")[len(dip) - 1:]
        lo = max(1, int(0.010 * fs / hop))       # ignore < 10 ms
        hi = min(len(acf), int(2.0 * fs / hop))  # ignore > 2 s
        if hi > lo + 1 and acf[0] > 0:
            peak = lo + int(np.argmax(acf[lo:hi]))
            if acf[peak] > 0.3 * acf[0]:
                acf_period_ms = peak * hop / fs * 1000.0
    return pops / fs, med_int, rate, dropout_frac, intervals, acf_period_ms


def spectral(x, fs, note_hz=None):
    """Non-harmonic vs fundamental (dB) on the loudest clean window of x."""
    n = 1 << 14
    if len(x) < n:
        n = 1 << int(np.floor(np.log2(len(x))))
    # Slide a window and pick the one with the steadiest (max) RMS, away from edges.
    best, best_rms = 0, -1.0
    step = n // 2
    for i in range(0, len(x) - n + 1, step):
        seg = x[i:i + n]
        r = np.sqrt((seg ** 2).mean())
        if r > best_rms:
            best_rms, best = r, i
    seg = x[best:best + n].copy()
    seg -= seg.mean()
    w = np.blackman(n)
    spec = np.abs(np.fft.rfft(seg * w))
    freqs = np.fft.rfftfreq(n, 1.0 / fs)
    # Fundamental: given or the loudest bin above 50 Hz.
    if note_hz:
        f0_bin = int(round(note_hz * n / fs))
    else:
        lo = int(50 * n / fs)
        f0_bin = lo + int(np.argmax(spec[lo:len(spec) // 2]))
    f0 = freqs[f0_bin]
    half = 6
    power = spec ** 2
    total = power[1:].sum()
    harm = 0.0
    k = 1
    harm_bins = set()
    while k * f0 < fs / 2:
        c = int(round(k * f0 * n / fs))
        for b in range(max(1, c - half), min(len(power), c + half + 1)):
            if b not in harm_bins:
                harm += power[b]
                harm_bins.add(b)
        k += 1
    fund = power[max(1, f0_bin - half):f0_bin + half + 1].sum()
    nonharm = total - harm
    def db(p):
        return 10 * np.log10(p / fund) if fund > 0 and p > 0 else float("-inf")
    return f0, db(nonharm), db(harm - fund), best / fs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--note-hz", type=float, default=None,
                    help="expected fundamental (Hz); else auto-detected")
    ap.add_argument("--start", type=float, default=0.0, help="skip first N sec")
    ap.add_argument("--dur", type=float, default=None, help="analyze N sec only")
    args = ap.parse_args()

    x, fs = decode(args.file)
    a = int(args.start * fs)
    b = a + int(args.dur * fs) if args.dur else len(x)
    x = x[a:b]
    if len(x) < fs // 4:
        sys.exit("recording too short after start/dur trim")

    peak = np.max(np.abs(x)) + 1e-12
    print(f"file        : {args.file}")
    print(f"sample rate : {fs} Hz")
    print(f"duration    : {len(x)/fs:.2f} s   peak={peak:.3f}  rms={np.sqrt((x**2).mean()):.4f}")
    print()

    pops, med_int, rate, dropout, intervals, acf_ms = find_pops(x, fs)
    print("--- pop / underrun detection ---")
    print(f"pops found      : {len(pops)}")
    if len(pops) >= 2:
        print(f"median interval : {med_int:.1f} ms  ->  {rate:.1f} pops/sec")
        print(f"interval spread : min={intervals.min():.1f}  max={intervals.max():.1f}  std={intervals.std():.1f} ms")
        cv = intervals.std() / (intervals.mean() + 1e-9)
        verdict = "CONSTANT interval (periodic stall, e.g. GC underrun)" if cv < 0.25 \
            else "irregular (jitter/one-off, less GC-like)"
        print(f"regularity      : CV={cv:.2f}  -> {verdict}")
    if acf_ms > 0:
        print(f"autocorr period : {acf_ms:.1f} ms  ->  {1000.0/acf_ms:.1f} /sec (dominant periodicity)")
    print(f"RMS dropout frac: {dropout*100:.2f}%  (fraction of 1 ms frames < half local level; high => holds/dropouts)")
    print()

    print("--- spectral purity (cleanest window) ---")
    f0, nonharm_db, harm_db, at = spectral(x, fs, args.note_hz)
    print(f"window start    : {at:.2f} s")
    print(f"fundamental     : {f0:.1f} Hz")
    print(f"non-harmonic    : {nonharm_db:+.1f} dB rel. fundamental")
    print(f"   reference: sine ~ very low | square polyBLEP ~ -35..-40 | square naive ~ -15..-20")
    print()
    print("interpretation:")
    print("  - constant-interval pops + dropouts => ring underrun (timing/GC), not the waveform")
    print("  - non-harmonic near -35..-40 on square => PolyBLEP is working on the board")


if __name__ == "__main__":
    main()
