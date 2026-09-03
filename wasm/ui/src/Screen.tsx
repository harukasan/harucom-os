// The DVI canvas, hosted but never owned by React.
//
// The engine holds a 2D context on this canvas and blits into it every committed
// frame. React must therefore never create or destroy it: re-creating the element
// would drop the context and the screen would freeze. So the canvas is created
// once outside React, passed in as a prop, and moved into an empty host div on
// mount. Because the element itself is the prop, a remount (switching dock modes
// tears this subtree down) can put the same canvas back, which getElementById
// could not do once the node had been detached.
import { useCallback, useEffect, useRef, useState } from "react";

export function Screen({ canvas }: { canvas: HTMLCanvasElement }) {
  // Two elements, because the canvas host must contain nothing but the canvas
  // (React manages this subtree, and the engine appends into it), while the
  // fullscreen element has to contain the button as well or there would be no
  // way out but the Escape key.
  const frame = useRef<HTMLDivElement>(null);
  const host = useRef<HTMLDivElement>(null);
  const [fullscreen, setFullscreen] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    host.current?.appendChild(canvas); // appendChild moves it if it is elsewhere
  }, [canvas]);

  // The browser paints the fullscreen element's own background behind the
  // content, so the frame carries one: without it the surround is white. Focus
  // moves back to the canvas afterwards, because the keyboard is the point of
  // running the screen fullscreen.
  const toggle = useCallback(() => {
    // Compared against the frame, not merely truthy: when something else on the
    // page is fullscreen the button reads "Fullscreen", and asking to exit would
    // take that other element out of fullscreen instead of showing the screen.
    if (document.fullscreenElement === frame.current) {
      document.exitFullscreen().catch(() => setError("Could not leave fullscreen."));
      return;
    }
    const request = frame.current?.requestFullscreen?.();
    // A refused request rejects: an iframe without allow="fullscreen", a
    // permissions policy, or a click the browser did not accept as activation.
    // Without this the click does nothing and the only sign is an uncaught
    // rejection in the console, which nobody looking at the page will see.
    if (!request) {
      setError("This browser will not show the screen fullscreen.");
      return;
    }
    request.then(() => {
      setError("");
      canvas.focus();
    }).catch(() => setError("The browser refused to show the screen fullscreen."));
  }, [canvas]);

  // The user can leave fullscreen without touching the button (Escape, or the
  // browser's own control), so the label follows the document rather than the
  // click that asked for it.
  useEffect(() => {
    const onChange = () => setFullscreen(document.fullscreenElement === frame.current);
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);

  return (
    <div
      ref={frame}
      className={`relative group leading-none ${fullscreen ? "w-full h-full bg-base grid place-items-center" : ""}`}
    >
      {/* index.css sizes #screen by id, which outranks a class, so the
          fullscreen size has to be marked important to win. The canvas scales to
          the height and keeps its aspect, so the pixels stay square. */}
      <div
        ref={host}
        className={fullscreen
          ? "grid place-items-center [&>canvas]:h-[100vh]! [&>canvas]:w-auto! [&>canvas]:max-w-[100vw]!"
          : "inline-block leading-none"}
      />
      <button
        type="button"
        aria-label={fullscreen ? "Leave fullscreen" : "Show the screen fullscreen"}
        // Out of the way until the pointer is over the screen, so it does not
        // sit on top of what the OS is drawing. It stops taking clicks while it
        // is invisible: a touch device never hovers, so otherwise a tap in that
        // corner of the screen would enter fullscreen with nothing to explain
        // it, and a mouse click meant for the canvas would be swallowed.
        className="absolute top-2 right-2 px-2 py-1 rounded bg-bar-bg/80 text-fg text-xs
                   border border-border opacity-0 pointer-events-none
                   group-hover:opacity-100 group-hover:pointer-events-auto
                   focus:opacity-100 focus:pointer-events-auto
                   transition-opacity cursor-pointer"
        onClick={toggle}
      >
        {fullscreen ? "Exit" : "Fullscreen"}
      </button>
      {error && (
        <p role="alert" className="absolute top-12 right-2 m-0 px-2 py-1 rounded bg-bar-bg/90
                                   text-ansi-red text-xs border border-border">
          {error}
        </p>
      )}
    </div>
  );
}
