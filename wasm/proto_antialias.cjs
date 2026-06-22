/*
 * Anti-aliasing method comparison for the Harucom PWM synth square/saw.
 *
 *   node wasm/proto_antialias.cjs
 *
 * Goal: find which practical method brings the square/sawtooth aliasing down to
 * "Famicom clean" (negligible audible non-harmonic content) at an RP2350-affordable
 * cost. We reproduce the synth's exact 32-bit phase math (verified bit-identical to
 * src/pwm_audio.c) and generate each waveform with several anti-aliasing methods,
 * then measure non-harmonic energy with the same FFT/window as measure_audio.cjs.
 *
 * Methods compared (square & saw, notes G3..C7):
 *   naive            -- current synth (point-sampled, the baseline)
 *   polyBLEP-2pt     -- cheap polynomial band-limited step at the edges
 *   BLEP-table       -- windowed-sinc step residual (high quality, table lookup)
 *   oversample Nx    -- render at N*fs, decimate with a windowed-sinc FIR
 *   ideal            -- additive band-limited reference (the unreachable ceiling)
 */
"use strict";

const FS = 22050;
const N = 16384;
const HALF = 6;
const TWO32 = 4294967296;

// --- exact synth phase increment: (freq << 32) / FS, as uint32 -------------
function incFor(freq, fs = FS) { return Number((BigInt(freq) << 32n) / BigInt(fs)); }

// === DSP helpers (copied from measure_audio.cjs to stay self-contained) =====
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = i + k + len / 2;
        const tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
        const ncr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}
function blackmanHarris(n) {
  const a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168, w = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const t = 2 * Math.PI * i / (n - 1);
    w[i] = a0 - a1 * Math.cos(t) + a2 * Math.cos(2 * t) - a3 * Math.cos(3 * t);
  }
  return w;
}
const WIN = blackmanHarris(N);
function powerSpectrum(s) {
  let mean = 0; for (let i = 0; i < N; i++) mean += s[i]; mean /= N;
  const re = new Float64Array(N), im = new Float64Array(N);
  for (let i = 0; i < N; i++) re[i] = (s[i] - mean) * WIN[i];
  fft(re, im);
  const P = new Float64Array(N / 2 + 1);
  for (let k = 0; k <= N / 2; k++) P[k] = re[k] * re[k] + im[k] * im[k];
  return P;
}
function nonHarmDb(P, f0, fs) {
  const binOf = (f) => Math.round(f * N / fs), mask = new Uint8Array(N / 2 + 1);
  let fundPow = 0;
  for (let h = 1; h * f0 < fs / 2; h++) {
    const b = binOf(h * f0); let pw = 0;
    for (let k = Math.max(1, b - HALF); k <= Math.min(N / 2, b + HALF); k++) { pw += P[k]; mask[k] = 1; }
    if (h === 1) fundPow = pw;
  }
  for (let k = 0; k <= HALF; k++) mask[k] = 1;
  let nonharm = 0;
  for (let k = 1; k <= N / 2; k++) if (!mask[k]) nonharm += P[k];
  return 10 * Math.log10(Math.max(nonharm / fundPow, 1e-300));
}

// --- analog model (mode1: RC low-pass + DC block), matches pwm_audio_wasm.c --
function analog(x) {
  const RC = 220.0 * 220e-9, DT = 1.0 / FS, A = DT / (RC + DT), R = 0.999;
  const y = new Float64Array(x.length);
  let lp = 0, dcx = 0, dcy = 0;
  for (let i = 0; i < x.length; i++) {
    lp += A * (x[i] - lp);
    const o = lp - dcx + R * dcy; dcx = lp; dcy = o; y[i] = o;
  }
  return y;
}

// === Waveform generators (bipolar [-1,1], length n) =========================
function naive(wave, freq, n, fs = FS) {
  const inc = incFor(freq, fs); let phase = 0; const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const t = phase / TWO32;
    out[i] = wave === "square" ? (t < 0.5 ? 1 : -1) : (2 * t - 1); // saw ramp -1..1
    phase = (phase + inc) % TWO32;
  }
  return out;
}
function polyBlep(t, dt) {
  if (t < dt) { const x = t / dt; return x + x - x * x - 1; }
  if (t > 1 - dt) { const x = (t - 1) / dt; return x * x + x + x + 1; }
  return 0;
}
function polyblep2(wave, freq, n) {
  const inc = incFor(freq); const dt = inc / TWO32; let phase = 0; const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const t = phase / TWO32;
    if (wave === "square") {
      let v = t < 0.5 ? 1 : -1;
      v += polyBlep(t, dt);
      let t2 = t + 0.5; if (t2 >= 1) t2 -= 1;
      v -= polyBlep(t2, dt);
      out[i] = v;
    } else {
      out[i] = (2 * t - 1) - polyBlep(t, dt); // saw: subtract BLEP at the wrap
    }
    phase = (phase + inc) % TWO32;
  }
  return out;
}

// BLEP table: windowed-sinc step residual, oversampled for fractional placement.
const BLEP_HALF = 16, BLEP_OS = 64; // +-16 samples, 64x sub-sample resolution
function buildBlepResidual() {
  const len = BLEP_HALF * 2 * BLEP_OS;
  const h = new Float64Array(len);
  for (let i = 0; i < len; i++) {
    const t = -BLEP_HALF + i / BLEP_OS;        // samples from center
    const s = t === 0 ? 1 : Math.sin(Math.PI * t) / (Math.PI * t);
    const w = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / (len - 1)) + 0.08 * Math.cos(4 * Math.PI * i / (len - 1));
    h[i] = s * w;
  }
  let total = 0; for (const v of h) total += v;
  const resid = new Float64Array(len);
  let acc = 0;
  for (let i = 0; i < len; i++) {
    acc += h[i];
    const t = -BLEP_HALF + i / BLEP_OS;
    resid[i] = acc / total - (t < 0 ? 0 : 1);  // bandlimited step - ideal step
  }
  return resid;
}
const BLEP = buildBlepResidual();
// Add a step of height `amp` whose edge is `frac` samples in the past relative
// to output index `idx` (frac in [0,1)). Residual centered at the edge.
function addBlep(out, idx, frac, amp) {
  for (let k = -BLEP_HALF + 1; k <= BLEP_HALF; k++) {
    const o = idx + k; if (o < 0 || o >= out.length) continue;
    // table position for sample at distance (k - frac) from the edge
    const tpos = (k - frac + BLEP_HALF) * BLEP_OS;
    const ti = Math.floor(tpos), tf = tpos - ti;
    if (ti < 0 || ti + 1 >= BLEP.length) continue;
    out[o] += amp * (BLEP[ti] + (BLEP[ti + 1] - BLEP[ti]) * tf);
  }
}
function bleptable(wave, freq, n) {
  const inc = incFor(freq); const dt = inc / TWO32; let phase = 0; const out = new Float64Array(n);
  let prevT = 0;
  for (let i = 0; i < n; i++) {
    const t = phase / TWO32;
    out[i] += wave === "square" ? (t < 0.5 ? 1 : -1) : (2 * t - 1);
    // detect edges crossed during this step (prevT -> t, possibly wrapping)
    const edges = wave === "square" ? [[0, 2], [0.5, -2]] : [[0, -2]]; // [pos, height]
    for (const [p, amp] of edges) {
      // did phase cross p between prevT and t (mod 1)?
      let crossed = false, frac = 0;
      if (t >= prevT) { // no wrap
        if (prevT < p && p <= t) { crossed = true; frac = (t - p) / dt; }
      } else { // wrapped through 1->0
        if (p > prevT) { crossed = true; frac = (t + 1 - p) / dt; }
        else if (p <= t) { crossed = true; frac = (t - p) / dt; }
      }
      if (crossed) addBlep(out, i, frac, amp);
    }
    prevT = t;
    phase = (phase + inc) % TWO32;
  }
  return out;
}

// Oversample Nx then decimate with a windowed-sinc FIR.
function windowedSincLP(numtaps, fc) {
  const h = new Float64Array(numtaps), M = numtaps - 1;
  for (let i = 0; i < numtaps; i++) {
    const nn = i - M / 2;
    const s = nn === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * nn) / (Math.PI * nn);
    const w = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / M) + 0.08 * Math.cos(4 * Math.PI * i / M);
    h[i] = s * w;
  }
  let s = 0; for (const v of h) s += v; for (let i = 0; i < numtaps; i++) h[i] /= s;
  return h;
}
function oversample(wave, freq, n, OSR, taps) {
  const fir = windowedSincLP(taps, 0.45 / OSR);   // cutoff a bit below new Nyquist
  const need = n * OSR + taps;
  const hi = naive(wave, freq, need, OSR * FS);    // naive at the oversampled rate
  const out = new Float64Array(n);
  const M = taps - 1;
  for (let i = 0; i < n; i++) {
    const center = i * OSR + M;                     // align decimation phase
    let acc = 0;
    for (let k = 0; k < taps; k++) { const idx = center - k; if (idx >= 0 && idx < need) acc += fir[k] * hi[idx]; }
    out[i] = acc;
  }
  return out;
}
function ideal(wave, freq, n) {
  const out = new Float64Array(n), nyq = FS / 2;
  for (let i = 0; i < n; i++) {
    const t = i / FS; let v = 0;
    if (wave === "square") { for (let h = 1; h * freq < nyq; h += 2) v += Math.sin(2 * Math.PI * h * freq * t) / h; v *= 4 / Math.PI; }
    else { for (let h = 1; h * freq < nyq; h++) v += Math.sin(2 * Math.PI * h * freq * t) / h; v *= 2 / Math.PI; }
    out[i] = v;
  }
  return out;
}

// === Run the comparison =====================================================
const NOTES = [
  { name: "G3", f: 196 }, { name: "G4", f: 392 }, { name: "G5", f: 784 },
  { name: "A5", f: 880 }, { name: "G6", f: 1568 }, { name: "C7", f: 2093 },
];
const METHODS = [
  ["naive", (w, f) => naive(w, f, N)],
  ["polyBLEP-2pt", (w, f) => polyblep2(w, f, N)],
  ["BLEP-table", (w, f) => bleptable(w, f, N)],
  ["oversample-2x/63", (w, f) => oversample(w, f, N, 2, 63)],
  ["oversample-4x/63", (w, f) => oversample(w, f, N, 4, 63)],
  ["oversample-8x/95", (w, f) => oversample(w, f, N, 8, 95)],
  ["ideal (ceiling)", (w, f) => ideal(w, f, N)],
];

for (const wave of ["square", "saw"]) {
  console.log("\n" + "=".repeat(86));
  console.log(`${wave.toUpperCase()}  --  non-harmonic vs fundamental (dB), AS HEARD (RC+DC, mode1)`);
  console.log("=".repeat(86));
  const head = "method".padEnd(20) + NOTES.map((nt) => nt.name.padStart(10)).join("");
  console.log(head);
  console.log("-".repeat(head.length));
  for (const [mname, gen] of METHODS) {
    let row = mname.padEnd(20);
    for (const nt of NOTES) {
      const sig = analog(gen(wave, nt.f));
      const dbv = nonHarmDb(powerSpectrum(sig), nt.f, FS);
      row += (dbv.toFixed(1) + "dB").padStart(10);
    }
    console.log(row);
  }
}

console.log("\n" + "=".repeat(86));
console.log("Lower (more negative) dB = cleaner. naive is the current synth; ideal is the ceiling.");
console.log("Target 'Famicom clean' ~ aliasing inaudible, roughly <= -40 dB across the musical range.");
console.log("=".repeat(86));
