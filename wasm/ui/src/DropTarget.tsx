// The page-wide drop affordance.
//
// The drop target is the whole page so the canvas is not a dead zone, and the
// panel that owns the transfer is unmounted whenever another tab is showing.
// The highlight therefore belongs here, above the panels: without it a drag over
// the page while the console is open changes nothing on screen, and there is no
// way to tell the page will take the file.
import { useFileTransfer } from "./useFileTransfer";
import type { ReactNode } from "react";

export function DropTarget({ children }: { children: ReactNode }) {
  const { dragging } = useFileTransfer();
  return (
    <div className={dragging ? "outline-2 outline-offset-[-2px] outline-accent" : ""}>
      {children}
    </div>
  );
}
