import { Console } from "../Console";
import type { PanelDefinition, PanelProps } from "./types";

function ConsolePanel({ log }: PanelProps) {
  return <Console log={log} />;
}

export const consolePanel: PanelDefinition = {
  slug: "console",
  title: "Console",
  Component: ConsolePanel,
};
