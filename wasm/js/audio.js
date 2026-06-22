// Audio: PWMAudio synth ring buffer -> Web Audio (AudioWorklet).
//
// The synth renders into a small ring (filled by the Ruby PWMAudio.update loop).
// A ScriptProcessor ran its callback on the busy main thread and glitched
// whenever a frame ran long. Instead an AudioWorklet (audio-worklet.js) plays on
// the dedicated audio thread (never blocked by the VM): it keeps its own ring
// and reports its fill level back, and the rAF loop (pump) pulls from the synth
// ring, resamples with a continuous fractional position, and posts frames to
// keep the worklet ~TARGET buffered.

// Install audio. Returns { startAudio, pump }: startAudio boots the AudioContext
// (must be called from a user gesture), and pump is called once per frame by the
// run loop (a no-op until the worklet is running). Also starts itself on a canvas
// click or any keydown.
export function installAudio(Module, canvas) {
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  let audioCtx = null, audioNode = null; // kept alive so the node is not GC'd
  let pumpFn = () => {};                  // real pump installed once the worklet loads

  function startAudio() {
    if (audioCtx || !AudioCtx) return;
    const srcRate = Module._harucom_audio_sample_rate(); // synth rate (PWM_AUDIO_SAMPLE_RATE)
    // Request the synth rate so the worklet needs no resampling when honored.
    try { audioCtx = new AudioCtx({ sampleRate: srcRate }); }
    catch (e) { audioCtx = new AudioCtx(); }
    const ctx = audioCtx;
    const ratio = srcRate / ctx.sampleRate; // source frames per output frame
    const TARGET = 3072; // output frames to keep buffered in the worklet (~140ms)
    const PULL = 1024;
    const lPtr = Module._malloc(PULL * 4), rPtr = Module._malloc(PULL * 4);
    let workletLevel = 0, workletUnder = 0; // from the worklet's reports

    // Source FIFO for continuous resampling: pulled synth frames awaiting
    // consumption; srcPos is the fractional read position (integer at ratio 1).
    const SF_CAP = 8192, SF_MASK = SF_CAP - 1;
    const sfL = new Float32Array(SF_CAP), sfR = new Float32Array(SF_CAP);
    let sfWr = 0, srcPos = 0;

    ctx.audioWorklet.addModule(new URL("./audio-worklet.js", import.meta.url)).then(() => {
      const node = new AudioWorkletNode(ctx, "harucom-audio", { numberOfInputs: 0, outputChannelCount: [2] });
      audioNode = node;
      node.port.onmessage = (e) => { workletLevel = e.data.lvl; workletUnder = e.data.under; };
      node.connect(ctx.destination);
      ctx.resume();
      console.log("Harucom audio: ctx " + ctx.sampleRate + "Hz, synth " +
                  srcRate + "Hz, ratio " + ratio.toFixed(4));

      // Flow control is time-based, not level-based: supply the frames the
      // worklet consumed since the last pump (wall-clock * rate) plus a gentle
      // pull toward TARGET. This is robust to the worklet's level reports being
      // delayed when the main thread is busy with the VM (a level-only scheme
      // then stalls supply and the worklet underruns -> choppy noise).
      let lastPump = 0, pumpCount = 0, maxWant = 0;
      pumpFn = function () {
        const now = performance.now();
        let want;
        if (lastPump === 0) {
          want = TARGET; // prime the buffer on the first pump
        } else {
          const consumed = (now - lastPump) / 1000 * ctx.sampleRate;
          want = Math.round(consumed + (TARGET - workletLevel) * 0.25);
        }
        lastPump = now;
        if (want <= 0) return;
        if (want > TARGET) want = TARGET; // cap a post-stall catch-up burst
        pumpCount++; if (want > maxWant) maxWant = want;
        const outL = new Float32Array(want), outR = new Float32Array(want);
        let produced = 0;
        while (produced < want) {
          // Keep at least two source frames ahead so linear interpolation has
          // both endpoints (at ratio 1 the fraction is 0, so this is exact).
          if (sfWr - Math.floor(srcPos) < 2) {
            const got = Module._harucom_audio_pull(lPtr, rPtr, PULL);
            if (got === 0) break; // synth ring empty; producer will refill
            const H = Module.HEAPF32, lo = lPtr >> 2, ro = rPtr >> 2;
            for (let i = 0; i < got; i++) {
              sfL[sfWr & SF_MASK] = H[lo + i];
              sfR[sfWr & SF_MASK] = H[ro + i];
              sfWr++;
            }
          }
          if (sfWr - Math.floor(srcPos) < 2) break;
          const i0 = Math.floor(srcPos), frac = srcPos - i0;
          const s0 = i0 & SF_MASK, s1 = (i0 + 1) & SF_MASK;
          outL[produced] = sfL[s0] + (sfL[s1] - sfL[s0]) * frac; // linear interp
          outR[produced] = sfR[s0] + (sfR[s1] - sfR[s0]) * frac;
          produced++;
          srcPos += ratio;
        }
        if (produced === 0) return;
        const L = produced === want ? outL : outL.slice(0, produced);
        const R = produced === want ? outR : outR.slice(0, produced);
        node.port.postMessage({ l: L, r: R }, [L.buffer, R.buffer]);
      };

      // Diagnostic: report worklet buffer health once a second. underruns
      // climbing means the pump cannot keep the worklet fed (choppy noise).
      setInterval(() => {
        console.log("audio diag: level=" + workletLevel + " underruns=" + workletUnder +
                    " pumps/s=" + pumpCount + " maxWant=" + maxWant);
        pumpCount = 0; maxWant = 0;
      }, 1000);
    });
  }

  // An AudioContext can only start from a user gesture.
  canvas.addEventListener("mousedown", startAudio);
  window.addEventListener("keydown", startAudio, true);

  return { startAudio, pump: () => pumpFn() };
}
