// AudioWorklet processor for Harucom OS audio playback.
//
// Runs on the dedicated audio thread (never blocked by the VM on the main
// thread). It keeps its own ring buffer, fed by the main thread via postMessage
// (so no SharedArrayBuffer, hence no cross-origin-isolation headers), and drains
// one frame per process() output sample. It reports its fill level and underrun
// count back so the main-thread pump (audio.js) can keep it ~TARGET buffered.

class HarucomAudio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.cap = 32768; this.mask = this.cap - 1;
    this.bl = new Float32Array(this.cap);
    this.br = new Float32Array(this.cap);
    this.wr = 0; this.rd = 0; this.under = 0;
    this.port.onmessage = (e) => {
      const l = e.data.l, r = e.data.r;
      for (let i = 0; i < l.length; i++) {
        this.bl[this.wr & this.mask] = l[i];
        this.br[this.wr & this.mask] = r[i];
        this.wr++;
      }
    };
  }
  process(inputs, outputs) {
    const out = outputs[0], outL = out[0], outR = out[1], n = outL.length;
    for (let i = 0; i < n; i++) {
      if (this.rd < this.wr) {
        const s = this.rd & this.mask;
        outL[i] = this.bl[s]; outR[i] = this.br[s]; this.rd++;
      } else { outL[i] = 0; outR[i] = 0; this.under++; }
    }
    this.port.postMessage({ lvl: this.wr - this.rd, under: this.under });
    return true;
  }
}
registerProcessor('harucom-audio', HarucomAudio);
