// Audio: PWMAudio synth -> Web Audio (AudioWorklet).
//
// harucom_audio_pull renders on demand, so there is no producer to wait for and
// no ring on the wasm side: asking for N frames renders exactly N. An
// AudioWorklet (audio-worklet.js) plays them on the dedicated audio thread,
// which the VM cannot block. It keeps its own ring and reports the fill level
// back, and the rAF loop (pump) pulls from the synth, resamples with a
// continuous fractional position when the context will not run at the synth
// rate, and posts frames to keep the worklet ~TARGET buffered.

// Install audio. Returns { pump }, called once per frame by the run loop (it
// drains the synth silently until the worklet is running). Audio arms itself
// from a user gesture, a canvas click or any keydown, which is what the autoplay
// policy requires.
export function installAudio(Module, canvas) {
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  let audioCtx = null, audioNode = null; // kept alive so the node is not GC'd

  // Until the worklet runs, drain the synth at wall-clock rate and throw the
  // frames away. Measured at about 0.1 ms per 60fps frame, roughly 0.6% of the
  // budget, whether the mixer is idle or playing eight channels, so it is not
  // worth an idle fast path. pwm_audio_sample_clock() only advances when something pulls, and
  // it is the clock scheduled events are compared against, so a silent pump keeps
  // a script that schedules before the first user gesture on real time instead of
  // piling every event at position zero.
  const DISCARD = 1024;
  const synthRate = Module._harucom_audio_sample_rate(); // a compile-time constant
  let discardPtrL = 0, discardPtrR = 0, discardLast = 0;
  function discardPump() {
    const now = performance.now();
    if (discardLast === 0) { discardLast = now; return; }
    let want = Math.round((now - discardLast) / 1000 * synthRate);
    discardLast = now;
    if (want <= 0) return;
    if (want > DISCARD * 8) want = DISCARD * 8; // cap a catch-up after a stall
    if (!discardPtrL) {
      discardPtrL = Module._malloc(DISCARD * 4);
      discardPtrR = Module._malloc(DISCARD * 4);
      // Pulling into address 0 would write floats over the null page.
      if (!discardPtrL || !discardPtrR) {
        console.error("Harucom audio: cannot allocate the discard buffers");
        discardPtrL = discardPtrR = 0;
        pumpFn = () => {};
        return;
      }
    }
    while (want > 0) {
      const n = want > DISCARD ? DISCARD : want;
      Module._harucom_audio_pull(discardPtrL, discardPtrR, n);
      want -= n;
    }
  }
  let pumpFn = discardPump; // replaced by the real pump once the worklet loads

  function startAudio() {
    if (audioCtx || !AudioCtx) return;
    const srcRate = synthRate;
    // Request the synth rate so the worklet needs no resampling when honored.
    try {
      // Ask for the synth rate so the worklet needs no resampling when honored,
      // and fall back to the default rate when it is not. Both can throw once a
      // page has opened too many contexts, which is why the whole thing is
      // guarded: this runs from an event handler.
      try { audioCtx = new AudioCtx({ sampleRate: srcRate }); }
      catch (e) { audioCtx = new AudioCtx(); }
    } catch (e) {
      console.error("Harucom audio: cannot create an AudioContext: " + e.message);
      audioCtx = null;
      return;
    }
    const ctx = audioCtx;
    const ratio = srcRate / ctx.sampleRate; // source frames per output frame
    // Output frames to keep buffered in the worklet: 61 ms at the 50 kHz synth
    // rate, 64 ms if the context runs at 48 kHz. This doubles as the per-pump
    // supply cap below, so it is also how long a blocked frame can run before
    // the worklet runs dry and the catch-up is clipped.
    const TARGET = 3072;
    const PULL = 1024;
    const lPtr = Module._malloc(PULL * 4), rPtr = Module._malloc(PULL * 4);
    // Pulling into address 0 would write floats over the null page.
    if (!lPtr || !rPtr) {
      console.error("Harucom audio: cannot allocate the pull buffers");
      releaseAudio(ctx);
      return;
    }
    let workletLevel = 0, workletUnder = 0, workletDropped = 0; // worklet reports

    // Give the context, its node and the buffers back. Every gesture retries, so
    // holding them would burn through the handful of contexts a page may open
    // and leak the buffers once per attempt.
    function releaseAudio(context) {
      context.close().catch(() => {});
      if (lPtr) Module._free(lPtr);
      if (rPtr) Module._free(rPtr);
      audioNode = null;
      audioCtx = null; // let a later gesture retry
      pumpFn = discardPump; // keep the sample clock on real time
    }

    // Source FIFO for continuous resampling: pulled synth frames awaiting
    // consumption. srcPos is the fractional read position (integer at ratio 1).
    const SF_CAP = 8192, SF_MASK = SF_CAP - 1;
    const sfL = new Float32Array(SF_CAP), sfR = new Float32Array(SF_CAP);
    let sfWr = 0, srcPos = 0;

    // AudioWorklet needs a secure context, so serving build/wasm over plain HTTP
    // to another device leaves this undefined and the call below would throw
    // synchronously, outside the promise chain that cleans up.
    if (!ctx.audioWorklet) {
      console.error("Harucom audio: no AudioWorklet (needs https or localhost), running silent");
      releaseAudio(ctx);
      return;
    }
    ctx.audioWorklet.addModule(new URL("./audio-worklet.js", import.meta.url)).then(() => {
      const node = new AudioWorkletNode(ctx, "harucom-audio", { numberOfInputs: 0, outputChannelCount: [2] });
      audioNode = node;
      // rake wasm:server restages the JavaScript without relinking, so a reload
      // can pair this file with a module built before the export existed.
      const report = Module._harucom_audio_report;
      if (!report) {
        console.warn("Harucom audio: harucom_audio_report is missing, so " +
                     "PWMAudio.stats will not see the consumer. Rebuild the wasm.");
      }
      node.port.onmessage = (e) => {
        workletLevel = e.data.lvl;
        workletUnder = e.data.under;
        workletDropped = e.data.dropped;
        // Only the worklet knows how the consumer is doing, so hand it to the
        // port for PWMAudio.stats.
        if (report) report(workletLevel);
      };
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
        // Nothing drains the worklet while the context is not running, so
        // supplying it would only fill the ring with frames that go stale. Keep
        // draining the synth though: render_position is the clock scheduled
        // events are compared against, and freezing it strands them.
        if (ctx.state !== "running") { lastPump = 0; discardPump(); return; }
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
            // Rendering is on demand, so this always returns PULL frames.
            const got = Module._harucom_audio_pull(lPtr, rPtr, PULL);
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

      // Report only when underruns grow: that is the symptom worth seeing
      // (the pump cannot keep the worklet fed, which sounds choppy). Logging
      // every second regardless would bury it.
      let lastUnder = 0, lastDropped = 0;
      setInterval(() => {
        if (workletUnder > lastUnder) {
          console.warn("Harucom audio: " + (workletUnder - lastUnder) +
                       " underruns in the last second (level=" + workletLevel +
                       ", pumps=" + pumpCount + ", maxWant=" + maxWant + ")");
          lastUnder = workletUnder;
        }
        // Over-supply makes the worklet drop what it cannot hold. That is the
        // mirror of an underrun and just as audible, so say so rather than
        // letting frames vanish silently.
        if (workletDropped > lastDropped) {
          console.warn("Harucom audio: " + (workletDropped - lastDropped) +
                       " frames dropped in the last second (level=" + workletLevel + ")");
          lastDropped = workletDropped;
        }
        pumpCount = 0; maxWant = 0;
      }, 1000);
    }).catch((e) => {
      // A stale build/wasm/js, a wrong MIME type, a syntax error.
      console.error("Harucom audio: worklet failed to load, running silent: " + e.message);
      releaseAudio(ctx);
    });
  }

  // An AudioContext can only start, or resume, from a user gesture. Browsers
  // suspend it again on their own (Safari when the tab goes to the background),
  // and startAudio returns early once the context exists, so a gesture has to
  // resume as well or audio stays dead until a reload. Using the OS means
  // pressing keys, so this recovers without the user having to know why.
  function armAudio() {
    if (!audioCtx) { startAudio(); return; }
    if (audioCtx.state === "suspended") audioCtx.resume();
  }
  canvas.addEventListener("mousedown", armAudio);
  window.addEventListener("keydown", armAudio, true);

  return { pump: () => pumpFn(), arm: armAudio };
}
