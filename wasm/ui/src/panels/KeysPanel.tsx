// What the last DOM key event turned into: the code, the HID usage, whether the
// browser was stopped from acting on it, and the resulting report. This is the
// panel to open when a key reaches the browser but not the OS.
import { useState } from "react";
import { useEngineEvent } from "../useEngineEvent";
import type { PanelDefinition, PanelProps } from "./types";

function KeysPanel({ engine }: PanelProps) {
  const [info, setInfo] = useState("");
  useEngineEvent(engine, "keys", setInfo);

  return (
    <div className="text-fg-dim font-mono text-xs h-full overflow-auto p-2">
      {info || "(no key yet)"}
    </div>
  );
}

export const keysPanel: PanelDefinition = {
  slug: "keys",
  title: "Keys",
  Component: KeysPanel,
};
