import { Pads } from "../Pads";
import type { PanelDefinition, PanelProps } from "./types";

function PadsPanel({ engine }: PanelProps) {
  return <Pads engine={engine} />;
}

export const padsPanel: PanelDefinition = {
  slug: "pads",
  title: "Pads",
  Component: PadsPanel,
};
