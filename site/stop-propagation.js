// Wrap interactive content in <stop-propagation> to keep its clicks from
// bubbling to ancestors — e.g. a button inside a <summary> whose click
// should not reach it:
//   <stop-propagation><button>Copy</button></stop-propagation>
// Nesting order decides where the click stops: wrappers that react to the
// click (like <click-notify>) must sit INSIDE this element, so the event
// reaches them before it is stopped here.
class StopPropagationElement extends HTMLElement {
  connectedCallback() {
    this.addEventListener("click", (event) => {
      event.stopPropagation();
      // Some browsers treat a child click as activating the enclosing
      // <summary>; cancel that toggle. A type="button" child has no
      // default action of its own to lose.
      if (this.closest("summary") !== null) {
        event.preventDefault();
      }
    });
  }
}

if (!customElements.get("stop-propagation")) {
  customElements.define("stop-propagation", StopPropagationElement);
}
