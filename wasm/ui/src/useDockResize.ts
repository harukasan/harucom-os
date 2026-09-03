// Drag an edge splitter to resize the dock.
//
// The size is written straight onto the dock element during the drag and only
// committed to React state on release. Re-rendering on every pointermove would
// re-run the panel tree (and its subscriptions) dozens of times a second for a
// number that is only a CSS length.
import { useCallback, useRef } from "react";
import type { PointerEvent as ReactPointerEvent, RefObject } from "react";

export const DOCK_MIN = 120;
export const DOCK_MAX = 900;

export function clampDock(size: number): number {
  if (size < DOCK_MIN) return DOCK_MIN;
  if (size > DOCK_MAX) return DOCK_MAX;
  return size;
}

export function useDockResize(
  dock: RefObject<HTMLElement | null>,
  vertical: boolean, // true when the dock is at the bottom and height is dragged
  size: number,
  commit: (size: number) => void,
) {
  const drag = useRef<{ origin: number; base: number; size: number } | null>(null);

  const onPointerDown = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    // Only the primary button. A right-press opens the context menu, which can
    // swallow the matching pointerup, and because the pointer is captured every
    // later move would go on resizing the dock with no button held.
    if (e.button !== 0) return;
    e.preventDefault();
    drag.current = { origin: vertical ? e.clientY : e.clientX, base: size, size };
    e.currentTarget.setPointerCapture(e.pointerId);
  }, [vertical, size]);

  const onPointerMove = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    const state = drag.current;
    if (!state) return;
    // Dragging the inner edge toward the screen grows the dock, so the delta is
    // measured from the pointer back to where the drag started.
    const position = vertical ? e.clientY : e.clientX;
    state.size = clampDock(state.base + (state.origin - position));
    const el = dock.current;
    if (el) el.style[vertical ? "height" : "width"] = `${state.size}px`;
  }, [dock, vertical]);

  const onPointerUp = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    const state = drag.current;
    if (!state) return;
    drag.current = null;
    // A cancelled pointer is no longer active, and releasing capture for one the
    // browser has forgotten throws. Commit first so a cancelled drag keeps the
    // size it reached rather than snapping back on the next render.
    commit(state.size);
    try {
      e.currentTarget.releasePointerCapture(e.pointerId);
    } catch {
      // the pointer is already gone
    }
  }, [commit]);

  return { onPointerDown, onPointerMove, onPointerUp, onPointerCancel: onPointerUp };
}
