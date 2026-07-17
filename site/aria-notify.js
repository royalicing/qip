// Bridges bubbling outcome events to screen-reader announcements, following
// the Document.ariaNotify proposal. Dispatch from any element:
//   el.dispatchEvent(new CustomEvent("qip:success", { bubbles: true, detail: "Copied" }));
//   el.dispatchEvent(new CustomEvent("qip:failed", { bubbles: true, detail: "Copy failed" }));
// A :root listener announces "qip:success" details at normal priority and
// "qip:failed" details at high priority (default "Failed"), via
// document.ariaNotify when the browser supports it, else visually-hidden
// live regions (styles in recipes/text/markdown/styles.css).

function liveRegionFallback() {
  const host = document.createElement("aria-notify");
  const statusRegion = document.createElement("span");
  statusRegion.setAttribute("role", "status");
  const alertRegion = document.createElement("span");
  alertRegion.setAttribute("role", "alert");
  host.append(statusRegion, alertRegion);
  document.body.append(host);
  return (message, priority) => {
    statusRegion.textContent = priority === "normal" ? message : "";
    alertRegion.textContent = priority === "high" ? message : "";
  };
}

const announce =
  typeof document.ariaNotify === "function"
    ? (message, priority) => document.ariaNotify(message, { priority })
    : liveRegionFallback();

document.documentElement.addEventListener("qip:success", (event) => {
  if (typeof event.detail === "string" && event.detail !== "") {
    announce(event.detail, "normal");
  }
});

document.documentElement.addEventListener("qip:failed", (event) => {
  const detail = event.detail;
  announce(
    typeof detail === "string" && detail !== "" ? detail : "Failed",
    "high",
  );
});
