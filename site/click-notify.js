// Wrap a button in <click-notify animate> to flash visual feedback when a
// child's async work completes. Children dispatch bubbling outcome events:
//   button.dispatchEvent(new CustomEvent("qip:success", { bubbles: true, detail: "Copied" }));
//   button.dispatchEvent(new CustomEvent("qip:failed", { bubbles: true, detail: "Copy failed" }));
// "qip:success" replays a ".succeeded" flash on the wrapper and "qip:failed" a red
// ".failed" one; CSS animates the inner button. The same events keep
// bubbling to :root, where /aria-notify.js turns their detail into
// screen-reader announcements — import both. Animations live in
// recipes/text/markdown/styles.css.

class ClickNotifyElement extends HTMLElement {
  #replayFlash(className) {
    this.classList.remove("succeeded");
    this.classList.remove("failed");
    void this.offsetWidth;
    this.classList.add(className);
  }

  connectedCallback() {
    this.addEventListener("qip:success", () => {
      if (this.hasAttribute("animate")) {
        this.#replayFlash("succeeded");
      }
    });
    this.addEventListener("qip:failed", () => {
      if (this.hasAttribute("animate")) {
        this.#replayFlash("failed");
      }
    });
    this.addEventListener("animationend", (event) => {
      if (event.animationName === "button-succeeded") {
        this.classList.remove("succeeded");
      }
      if (event.animationName === "button-failed") {
        this.classList.remove("failed");
      }
    });
  }
}

if (!customElements.get("click-notify")) {
  customElements.define("click-notify", ClickNotifyElement);
}
