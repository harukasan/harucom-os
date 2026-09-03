// jsdom has no pointer capture. The shell calls it so a press that slides off a
// button still releases, so stub it rather than let every pointer test throw.
if (!Element.prototype.setPointerCapture) {
  Element.prototype.setPointerCapture = () => {};
  Element.prototype.releasePointerCapture = () => {};
}
