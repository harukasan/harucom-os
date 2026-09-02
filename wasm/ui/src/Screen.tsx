// The DVI canvas, hosted but never owned by React.
//
// The engine holds a 2D context on this canvas and blits into it every committed
// frame. React must therefore never create or destroy it: re-creating the element
// would drop the context and the screen would freeze. So the canvas is created
// once outside React, passed in as a prop, and moved into an empty host div on
// mount. Because the element itself is the prop, a remount (switching dock modes
// tears this subtree down) can put the same canvas back, which getElementById
// could not do once the node had been detached.
import { useEffect, useRef } from "react";

export function Screen({ canvas }: { canvas: HTMLCanvasElement }) {
  const host = useRef<HTMLDivElement>(null);

  useEffect(() => {
    host.current?.appendChild(canvas); // appendChild moves it if it is elsewhere
  }, [canvas]);

  return <div ref={host} className="inline-block leading-none" />;
}
