// Where the panel host sits relative to the screen.
export type DockPosition = "undocked" | "bottom" | "right";

export const DOCK_CHOICES: { position: DockPosition; label: string; glyph: string }[] = [
  { position: "undocked", label: "Undock the panels", glyph: "▢" },
  { position: "bottom", label: "Dock the panels below", glyph: "⊥" },
  { position: "right", label: "Dock the panels to the right", glyph: "⊣" },
];
