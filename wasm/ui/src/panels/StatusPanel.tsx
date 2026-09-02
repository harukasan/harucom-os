// A small readout of how the runtime is doing: how many frames the OS has
// committed, and whether the audio worklet is being fed.
import { useState } from "react";
import { useEngineEvent } from "../useEngineEvent";
import type { AudioDiagnostics } from "../engine";
import type { PanelDefinition, PanelProps } from "./types";

// Frames tick about sixty times a second. Re-rendering on each one would spend
// the whole idle budget on a number nobody reads that closely, so sample it.
const FRAME_SAMPLE = 30;

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex gap-2 py-0.5">
      <span className="w-24 text-fg-dim">{label}</span>
      <span>{value}</span>
    </div>
  );
}

function StatusPanel({ engine }: PanelProps) {
  const [frame, setFrame] = useState(0);
  const [audio, setAudio] = useState<AudioDiagnostics | null>(null);

  useEngineEvent(engine, "frame", (n) => {
    if (n % FRAME_SAMPLE === 0) setFrame(n);
  });
  useEngineEvent(engine, "audio", setAudio);

  return (
    <div className="font-mono text-xs h-full overflow-auto p-3 text-fg">
      <Row label="frame" value={String(frame)} />
      {/* Until the worklet starts there is nothing to report, and showing zeros
          would read as healthy rather than as not yet running. */}
      <Row label="audio" value={audio ? "running" : "not started"} />
      {audio && <Row label="level" value={String(audio.level)} />}
      {audio && <Row label="underruns" value={String(audio.underruns)} />}
      {audio && <Row label="dropped" value={String(audio.dropped)} />}
    </div>
  );
}

export const statusPanel: PanelDefinition = {
  slug: "status",
  title: "Status",
  Component: StatusPanel,
};
