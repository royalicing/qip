class CopyCodeElement extends HTMLElement {
  connectedCallback() {
    if (this.querySelector(":scope > button")) return;

    const code = this.querySelector("pre > code");
    if (!code) return;

    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Copy code";
    button.addEventListener("animationend", () => {
      button.classList.remove("succeeded");
    });
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.textContent ?? "");
        button.textContent = "Copy code";
        button.classList.remove("succeeded");
        void button.offsetWidth;
        button.classList.add("succeeded");
      } catch {
        button.textContent = "Copy failed";
      }
    });
    this.append(button);
  }
}

if (!customElements.get("copy-code")) {
  customElements.define("copy-code", CopyCodeElement);
}
