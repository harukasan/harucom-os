// Tiny event bus for the Engine facade.
//
// on(event, cb) subscribes and returns an unsubscribe function; emit(event,
// ...args) calls every current subscriber. Listeners are snapshotted before
// dispatch so a handler may unsubscribe during emit without skipping others.

export function createEventBus() {
  const listeners = new Map(); // event name -> array of callbacks

  function on(event, cb) {
    let arr = listeners.get(event);
    if (!arr) listeners.set(event, (arr = []));
    arr.push(cb);
    return () => {
      const i = arr.indexOf(cb);
      if (i >= 0) arr.splice(i, 1);
    };
  }

  function emit(event, ...args) {
    const arr = listeners.get(event);
    if (arr) for (const cb of arr.slice()) cb(...args);
  }

  return { on, emit };
}
