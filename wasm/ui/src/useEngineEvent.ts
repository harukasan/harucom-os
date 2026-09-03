// Subscribe to an engine event for as long as a component is mounted.
//
// The handler is kept in a ref so a component that re-renders (which is every
// event, since these handlers set state) does not tear the subscription down and
// build it again. Only the engine or the event name can do that.
import { useEffect, useRef } from "react";
import type { Engine, EngineEvents } from "./engine";

export function useEngineEvent<E extends keyof EngineEvents>(
  engine: Engine,
  event: E,
  handler: (value: EngineEvents[E]) => void,
): void {
  const latest = useRef(handler);
  latest.current = handler;
  useEffect(() => engine.on(event, (value) => latest.current(value)), [engine, event]);
}
