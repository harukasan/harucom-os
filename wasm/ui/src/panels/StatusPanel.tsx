// What the runtime is doing: frames committed, how the audio worklet is coping,
// and what the last key event became.
//
// The key readout is here rather than on a tab of its own because it is the same
// question as the rest: not what the OS is showing, but whether the machine
// under it is working. It is the line to read when a key reaches the browser but
// not the OS.
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
      <span className="w-24 shrink-0 text-fg-dim">{label}</span>
      <span className="break-all">{value}</span>
    </div>
  );
}

function StatusPanel({ engine }: PanelProps) {
  const [frame, setFrame] = useState(0);
  const [audio, setAudio] = useState<AudioDiagnostics | null>(null);
  const [keys, setKeys] = useState("");

  useEngineEvent(engine, "frame", (n) => {
    if (n % FRAME_SAMPLE === 0) setFrame(n);
  });
  useEngineEvent(engine, "audio", setAudio);
  useEngineEvent(engine, "keys", setKeys);

  return (
    <div className="font-mono text-xs h-full overflow-auto p-3 text-fg">
      <Row label="frame" value={String(frame)} />
      {/* Until the worklet starts there is nothing to report, and showing zeros
          would read as healthy rather than as not yet running. */}
      <Row label="audio" value={audio ? "running" : "not started"} />
      {audio && <Row label="level" value={String(audio.level)} />}
      {audio && <Row label="underruns" value={String(audio.underruns)} />}
      {audio && <Row label="dropped" value={String(audio.dropped)} />}
      <Row label="last key" value={keys || "(none yet)"} />
    </div>
  );
}

export const statusPanel: PanelDefinition = {
  slug: "status",
  title: "Status",
  Component: StatusPanel,
};
