// Tiny event bus for the engine facade.
//
// on(event, callback) subscribes and returns an unsubscribe function. emit
// calls every current subscriber. The listener list is copied before dispatch so
// a handler that unsubscribes (a React effect cleaning up mid-emit) does not
// make the loop skip the handler after it.
export function createEventBus() {
  const listeners = new Map(); // event name -> array of callbacks

  function on(event, callback) {
    let list = listeners.get(event);
    if (!list) listeners.set(event, (list = []));
    list.push(callback);
    return () => {
      const i = list.indexOf(callback);
      if (i >= 0) list.splice(i, 1);
    };
  }

  function emit(event, ...args) {
    const list = listeners.get(event);
    if (list) for (const callback of list.slice()) callback(...args);
  }

  return { on, emit };
}
