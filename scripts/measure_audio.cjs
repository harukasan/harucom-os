/*
 * Headless spectral analysis of the Harucom OS PWM synth (wasm build).
 *
 *   node scripts/measure_audio.cjs
 *
 * Goal: decide whether the residual audible noise on sine AND square (e.g. G5)
 * is the synth's own quantization/aliasing (identical on the board, since the
 * synth C code is shared) or something the wasm-only playback path adds.
 *
 * Method: capture a clean, continuous, underrun-free stream straight from the
 * synth via harucom_audio_measure_pull (no Ruby boot needed), then DFT it.
 *   mode 0 = raw normalized synth duty (pure digital synth, board-identical)
 *   mode 1 = + analog model (RC low-pass + DC block), the board analog output
 * For each tone we separate fundamental / harmonics / non-harmonic energy and
 * list the loudest non-harmonic spurs. We then:
 *   - compare to an IDEAL band-limited waveform (no aliasing) to quantify how
 *     much of the non-harmonic energy is aliasing vs numerical floor;
 *   - simulate the JS linear-interpolation resampler (22050 -> 44100 / 48000,
 *     the exact code from js/audio.js) to see if it ADDS non-harmonic energy
 *     (the wasm-only contribution, present only if the browser does not honor a
 *     22050 Hz AudioContext).
 */
"use strict";

// No DOM needed: this measures the pure C synth (harucom_audio_measure_*) and
// never calls harucom_init, so the picoruby-wasm gem's DOM-dependent JS init
// never runs.
const createHarucomModule = require("../build/wasm/harucom.js");

const FS = 22050;        // synth sample rate
const N = 16384;         // FFT length (power of 2)
const WARMUP = 8192;     // discarded so RC/DC filters settle
const HALF = 6;          // bins each side of a harmonic counted as "harmonic"

// Waveform enum (must match pwm_audio.h).
const WAVE = { SINE: 0, SQUARE: 1, TRIANGLE: 2, SAWTOOTH: 3 };
const WAVE_NAME = ["sine", "square", "triangle", "sawtooth"];

// --- Minimal iterative radix-2 FFT (in-place, complex re/im arrays) ----------
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = i + k + len / 2;
        const tr = re[b] * cr - im[b] * ci;
        const ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr; im[a] += ti;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}

// 4-term Blackman-Harris window (-92 dB sidelobes) for a clean non-harmonic floor.
function blackmanHarris(n) {
  const a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168;
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const t = 2 * Math.PI * i / (n - 1);
    w[i] = a0 - a1 * Math.cos(t) + a2 * Math.cos(2 * t) - a3 * Math.cos(3 * t);
  }
  return w;
}
const WIN = blackmanHarris(N);

// Power spectrum (k = 0..N/2) of a real signal, mean-removed and windowed.
function powerSpectrum(samples) {
  let mean = 0;
  for (let i = 0; i < N; i++) mean += samples[i];
  mean /= N;
  const re = new Float64Array(N), im = new Float64Array(N);
  for (let i = 0; i < N; i++) re[i] = (samples[i] - mean) * WIN[i];
  fft(re, im);
  const P = new Float64Array(N / 2 + 1);
  for (let k = 0; k <= N / 2; k++) P[k] = re[k] * re[k] + im[k] * im[k];
  return P;
}

// Separate a power spectrum into harmonic vs non-harmonic energy for a tone of
// frequency f0 at sample rate fs. Returns powers and the loudest non-harmonic spurs.
function analyze(P, f0, fs) {
  const nyq = fs / 2;
  const binOf = (freq) => Math.round(freq * N / fs);
  const harmonicBin = new Uint8Array(N / 2 + 1);
  const harmonics = [];
  for (let h = 1; h * f0 < nyq; h++) {
    const b = binOf(h * f0);
    let pw = 0;
    for (let k = Math.max(1, b - HALF); k <= Math.min(N / 2, b + HALF); k++) {
      pw += P[k];
      harmonicBin[k] = 1;
    }
    harmonics.push({ h, freq: h * f0, power: pw });
  }
  // Also mask DC neighborhood so residual DC does not count as noise.
  for (let k = 0; k <= HALF; k++) harmonicBin[k] = 1;

  let total = 0, harm = 0, nonharm = 0;
  for (let k = 1; k <= N / 2; k++) {
    total += P[k];
    if (harmonicBin[k]) harm += P[k]; else nonharm += P[k];
  }
  const fundPower = harmonics[0] ? harmonics[0].power : 0;

  // Loudest non-harmonic spurs: local maxima among unmasked bins.
  const spurs = [];
  for (let k = 2; k < N / 2; k++) {
    if (harmonicBin[k]) continue;
    if (P[k] > P[k - 1] && P[k] >= P[k + 1] && P[k] > fundPower * 1e-7) {
      spurs.push({ freq: k * fs / N, power: P[k] });
    }
  }
  spurs.sort((a, b) => b.power - a.power);

  return { total, harm, nonharm, fundPower, harmonics, spurs: spurs.slice(0, 8) };
}

const db = (ratio) => 10 * Math.log10(Math.max(ratio, 1e-300));
const pct = (ratio) => (Math.sqrt(Math.max(ratio, 0)) * 100);

function report(label, A) {
  const thd = Math.sqrt(A.harmonics.slice(1).reduce((s, h) => s + h.power, 0) / A.fundPower);
  const nonharmRel = A.nonharm / A.fundPower;   // power ratio vs fundamental
  const nonharmTot = A.nonharm / A.total;       // fraction of total power
  console.log(`  [${label}]`);
  console.log(`    fundamental power      : 1.000 (ref)`);
  console.log(`    THD (harmonics 2..)    : ${(thd * 100).toFixed(3)} %   (${db(thd * thd).toFixed(1)} dB)`);
  console.log(`    non-harmonic vs fund.  : ${pct(nonharmRel).toFixed(3)} %   (${db(nonharmRel).toFixed(1)} dB)`);
  console.log(`    non-harmonic of total  : ${pct(nonharmTot).toFixed(3)} %   (${db(nonharmTot).toFixed(1)} dB)`);
  const top = A.spurs.slice(0, 6).map((s) =>
    `${s.freq.toFixed(0)}Hz@${db(s.power / A.fundPower).toFixed(0)}dB`).join("  ");
  console.log(`    top non-harm spurs     : ${top || "(none above floor)"}`);
}

// --- Reference: ideal band-limited waveform (no aliasing) --------------------
// Additive synthesis up to Nyquist, unit amplitude, centered on 0.
function idealBandlimited(waveform, f0, fs, n) {
  const out = new Float64Array(n);
  const nyq = fs / 2;
  for (let i = 0; i < n; i++) {
    const t = i / fs;
    let v = 0;
    if (waveform === WAVE.SINE) {
      v = Math.sin(2 * Math.PI * f0 * t);
    } else if (waveform === WAVE.SQUARE) {
      for (let h = 1; h * f0 < nyq; h += 2) v += (1 / h) * Math.sin(2 * Math.PI * h * f0 * t);
      v *= 4 / Math.PI;
    } else if (waveform === WAVE.SAWTOOTH) {
      for (let h = 1; h * f0 < nyq; h++) v += (1 / h) * Math.sin(2 * Math.PI * h * f0 * t);
      v *= 2 / Math.PI;
    } else { // triangle
      let sign = 1;
      for (let h = 1; h * f0 < nyq; h += 2) { v += sign * (1 / (h * h)) * Math.sin(2 * Math.PI * h * f0 * t); sign = -sign; }
      v *= 8 / (Math.PI * Math.PI);
    }
    out[i] = v;
  }
  return out;
}

// --- JS linear-interpolation resampler (exact copy of index.html audioPump) --
// Resample a source stream at FS to targetRate, returning `n` output frames.
function resampleLinear(src, targetRate, n) {
  const ratio = FS / targetRate; // source frames per output frame
  const out = new Float64Array(n);
  let srcPos = 0;
  for (let i = 0; i < n; i++) {
    const i0 = Math.floor(srcPos), frac = srcPos - i0;
    if (i0 + 1 >= src.length) break;
    out[i] = src[i0] + (src[i0 + 1] - src[i0]) * frac;
    srcPos += ratio;
  }
  return out;
}

createHarucomModule({ print: () => {}, printErr: () => {} }).then((Module) => {
  const TOTAL = WARMUP + N;
  const bufPtr = Module._malloc(TOTAL * 4);

  function capture(waveform, f0, mode, volume = 15) {
    Module._harucom_audio_measure_tone(0, f0, waveform, volume);
    const got = Module._harucom_audio_measure_pull(bufPtr, TOTAL, mode);
    const H = Module.HEAPF32, base = bufPtr >> 2;
    const out = new Float64Array(N);
    for (let i = 0; i < N; i++) out[i] = H[base + WARMUP + i];
    return { out, got };
  }

  // Musical notes for the square sweep (the user reported G5 noise).
  const NOTES = [
    { name: "A4", f: 440 },
    { name: "G3", f: 196 },
    { name: "G4", f: 392 },
    { name: "G5", f: 784 },
    { name: "G6", f: 1568 },
  ];

  console.log("=".repeat(72));
  console.log(`Harucom synth spectral analysis  (fs=${FS}, N=${N}, Blackman-Harris)`);
  console.log("=".repeat(72));

  // 1. Sine and square at the notes, mode 0 (pure synth) and mode 1 (analog).
  for (const wf of [WAVE.SINE, WAVE.SQUARE]) {
    for (const note of NOTES) {
      console.log(`\n### ${WAVE_NAME[wf]} ${note.name} (${note.f} Hz)`);
      for (const mode of [0, 1]) {
        const { out, got } = capture(wf, note.f, mode);
        if (got < TOTAL) { console.log(`  (short capture: ${got}/${TOTAL})`); continue; }
        const A = analyze(powerSpectrum(out), note.f, FS);
        report(mode === 0 ? "mode0 pure-synth" : "mode1 +analog(RC+DC)", A);
      }
      // Ideal band-limited reference (no aliasing) for the same tone, raw.
      const ideal = idealBandlimited(wf, note.f, FS, N);
      const Ai = analyze(powerSpectrum(ideal), note.f, FS);
      report("ideal band-limited (ref)", Ai);
    }
  }

  // 2. Resampler check: does the JS linear interp ADD non-harmonic energy?
  //    Capture a long mode-1 source, resample to 44100/48000, re-analyze.
  console.log("\n" + "=".repeat(72));
  console.log("JS linear-interp resampler effect (22050 -> ctx rate), square G5 & sine A4");
  console.log("=".repeat(72));
  const LONG = WARMUP + N * 4;
  const longPtr = Module._malloc(LONG * 4);
  function captureLong(waveform, f0, mode) {
    Module._harucom_audio_measure_tone(0, f0, waveform, mode === undefined ? 15 : 15);
    const got = Module._harucom_audio_measure_pull(longPtr, LONG, mode);
    const H = Module.HEAPF32, base = longPtr >> 2;
    const out = new Float64Array(got - WARMUP);
    for (let i = 0; i < out.length; i++) out[i] = H[base + WARMUP + i];
    return out;
  }
  for (const tc of [{ wf: WAVE.SQUARE, note: NOTES[3] }, { wf: WAVE.SINE, note: NOTES[0] }]) {
    console.log(`\n### ${WAVE_NAME[tc.wf]} ${tc.note.name} (${tc.note.f} Hz)`);
    const src = captureLong(tc.wf, tc.note.f, 1);
    const srcA = analyze(powerSpectrum(src.subarray(0, N)), tc.note.f, FS);
    report("source 22050 (ratio=1, no resample)", srcA);
    for (const rate of [44100, 48000]) {
      const rs = resampleLinear(src, rate, N);
      const A = analyze(powerSpectrum(rs), tc.note.f, rate);
      report(`resampled to ${rate}`, A);
    }
  }
  Module._free(longPtr);
  Module._free(bufPtr);

  console.log("\n" + "=".repeat(72));
  console.log("Interpretation:");
  console.log("  - If mode0 non-harmonic ~= ideal floor  -> synth is clean (LUT/aliasing negligible)");
  console.log("  - If mode0 >> ideal                      -> synth aliasing/quant (BOARD-IDENTICAL)");
  console.log("  - If resampled >> source 22050           -> JS resampler adds noise (WASM-ONLY)");
  console.log("=".repeat(72));
  process.exit(0);
}).catch((e) => { console.error("error:", e); process.exit(1); });
