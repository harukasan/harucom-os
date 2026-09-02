import type { ComponentType } from "react";
import type { ConsoleLog, Engine } from "../engine";

export interface PanelProps {
  engine: Engine;
  log: ConsoleLog;
}

export interface PanelDefinition {
  /** Identifies the panel in the tab state. */
  slug: string;
  /** The tab label. */
  title: string;
  Component: ComponentType<PanelProps>;
}
