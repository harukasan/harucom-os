// The panels the shell offers, in tab order.
//
// A plain list rather than self-registration: the order is the point, and it is
// easier to read here than spread across the panel files.
import { consolePanel } from "./ConsolePanel";
import { filesPanel } from "./FilesPanel";
import { keyboardPanel } from "./KeyboardPanel";
import { keysPanel } from "./KeysPanel";
import { padsPanel } from "./PadsPanel";
import { statusPanel } from "./StatusPanel";
import type { PanelDefinition } from "./types";

export const PANELS: PanelDefinition[] = [consolePanel, filesPanel, keysPanel, keyboardPanel, padsPanel, statusPanel];
export type { PanelDefinition, PanelProps } from "./types";
