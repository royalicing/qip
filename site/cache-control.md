<title>Cache-Control interactive explainer</title>

# Cache-Control interactive explainer

Change the response policy and watch how the browser cache changes the next request.

<style>
.cache-demo {
  display: grid;
  gap: 1rem;
}
.cache-modes,
.cache-controls,
.cache-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.cache-modes button[aria-pressed="true"] {
  outline: 2px solid currentColor;
  outline-offset: 2px;
}
.cache-controls label {
  display: inline-grid;
  gap: 0.25rem;
}
.cache-controls input {
  width: 7em;
  font: inherit;
}
.cache-summary {
  padding: 0.75rem;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
}
.cache-chain {
  display: grid;
  gap: 0.75rem;
}
.cache-event {
  display: grid;
  gap: 0.5rem;
  padding: 0.75rem;
  border-left: 0.35rem solid currentColor;
  background: color-mix(in srgb, currentColor 8%, transparent);
}
.cache-event h3,
.cache-event p {
  margin-bottom: 0;
}
.cache-columns {
  display: grid;
  gap: 0.75rem;
}
@media (min-width: 760px) {
  .cache-columns { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
.cache-box {
  min-width: 0;
}
.cache-box strong {
  display: block;
  margin-bottom: 0.25rem;
}
.cache-box pre {
  min-height: 7rem;
  padding: 0.5rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
  white-space: pre-wrap;
}
.cache-state {
  display: grid;
  gap: 0.5rem;
  grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
}
.cache-pill {
  padding: 0.5rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
</style>

<section class="cache-demo" aria-labelledby="cache-demo-heading">
  <h2 id="cache-demo-heading">Policy</h2>

  <div class="cache-modes" role="group" aria-label="Cache-Control policy">
    <button type="button" data-mode="max-age">max-age</button>
    <button type="button" data-mode="no-cache">no-cache</button>
    <button type="button" data-mode="no-store">no-store</button>
    <button type="button" data-mode="immutable">immutable</button>
    <button type="button" data-mode="stale">stale-while-revalidate</button>
  </div>

  <div class="cache-controls">
    <label>
      max-age seconds
      <input id="max-age" type="number" min="0" max="31536000" step="1" value="60" />
    </label>
    <label>
      stale-while-revalidate seconds
      <input id="stale-age" type="number" min="0" max="31536000" step="1" value="120" />
    </label>
    <label>
      resource changes at second
      <input id="change-at" type="number" min="0" max="31536000" step="1" value="90" />
    </label>
  </div>

  <div class="cache-actions">
    <button type="button" data-visit="0">Visit at 0s</button>
    <button type="button" data-visit="30">Visit at 30s</button>
    <button type="button" data-visit="75">Visit at 75s</button>
    <button type="button" data-visit="150">Visit at 150s</button>
    <button id="reset-cache" type="button">Reset cache</button>
  </div>

  <div id="cache-summary" class="cache-summary"></div>
  <div id="cache-state" class="cache-state"></div>
  <div id="cache-chain" class="cache-chain" aria-live="polite"></div>
</section>

<script type="module">
const modeButtons = [...document.querySelectorAll("[data-mode]")];
const visitButtons = [...document.querySelectorAll("[data-visit]")];
const maxAgeInput = document.getElementById("max-age");
const staleAgeInput = document.getElementById("stale-age");
const changeAtInput = document.getElementById("change-at");
const resetButton = document.getElementById("reset-cache");
const summary = document.getElementById("cache-summary");
const state = document.getElementById("cache-state");
const chain = document.getElementById("cache-chain");

let mode = "max-age";
let cacheEntry = null;
let events = [];

function seconds(input) {
  return Math.max(0, Number.parseInt(input.value, 10) || 0);
}

function currentPolicy() {
  const maxAge = seconds(maxAgeInput);
  const staleAge = seconds(staleAgeInput);
  if (mode === "no-store") return { header: "Cache-Control: no-store", maxAge: 0, staleAge: 0, store: false };
  if (mode === "no-cache") return { header: "Cache-Control: no-cache", maxAge: 0, staleAge: 0, store: true };
  if (mode === "immutable") return { header: `Cache-Control: public, max-age=${maxAge}, immutable`, maxAge, staleAge: 0, store: true };
  if (mode === "stale") return { header: `Cache-Control: public, max-age=${maxAge}, stale-while-revalidate=${staleAge}`, maxAge, staleAge, store: true };
  return { header: `Cache-Control: public, max-age=${maxAge}`, maxAge, staleAge: 0, store: true };
}

function originVersion(at) {
  return at >= seconds(changeAtInput) ? 2 : 1;
}

function etag(version) {
  return `"asset-v${version}"`;
}

function statusForValidation(at, requestHeaders) {
  const version = originVersion(at);
  if (requestHeaders.includes(`If-None-Match: ${etag(version)}`)) {
    return { status: "304 Not Modified", version, body: "" };
  }
  return { status: "200 OK", version, body: `body: asset v${version}` };
}

function requestHeaderLines(validation) {
  const lines = ["GET /asset.css HTTP/1.1"];
  if (validation && cacheEntry) {
    lines.push(`If-None-Match: ${cacheEntry.etag}`);
  }
  return lines;
}

function responseHeaderLines(response, policy) {
  const lines = [`HTTP/1.1 ${response.status}`, policy.header];
  if (response.status === "200 OK") {
    lines.push(`ETag: ${etag(response.version)}`);
  }
  return lines;
}

function store(response, at, policy) {
  if (!policy.store || response.status !== "200 OK") return;
  cacheEntry = {
    storedAt: at,
    version: response.version,
    etag: etag(response.version),
    freshUntil: at + policy.maxAge,
    staleUntil: at + policy.maxAge + policy.staleAge,
    policy,
  };
}

function revalidate(at, reason) {
  const policy = currentPolicy();
  const request = requestHeaderLines(true);
  const response = statusForValidation(at, request.join("\n"));
  if (response.status === "200 OK") {
    store(response, at, policy);
  } else if (cacheEntry) {
    cacheEntry.storedAt = at;
    cacheEntry.freshUntil = at + policy.maxAge;
    cacheEntry.staleUntil = at + policy.maxAge + policy.staleAge;
  }
  return {
    at,
    title: reason,
    cache: "Browser validates the cached response before using it.",
    request: request.join("\n"),
    response: responseHeaderLines(response, policy).join("\n"),
    result: response.status === "304 Not Modified" ? `Use cached body v${cacheEntry.version}` : `Use new body v${response.version}`,
  };
}

function visit(at) {
  const policy = currentPolicy();
  let event;

  if (!cacheEntry) {
    const request = requestHeaderLines(false);
    const response = statusForValidation(at, "");
    store(response, at, policy);
    event = {
      at,
      title: "Cold cache",
      cache: "Nothing is stored, so the browser asks the origin.",
      request: request.join("\n"),
      response: responseHeaderLines(response, policy).join("\n"),
      result: policy.store ? `Store body v${response.version}` : `Use body v${response.version}, then do not store it`,
    };
  } else if (mode === "no-store") {
    cacheEntry = null;
    const request = requestHeaderLines(false);
    const response = statusForValidation(at, "");
    event = {
      at,
      title: "No stored response",
      cache: "`no-store` means the browser must not keep a reusable response.",
      request: request.join("\n"),
      response: responseHeaderLines(response, policy).join("\n"),
      result: `Use body v${response.version}, then discard it`,
    };
  } else if (mode === "no-cache") {
    event = revalidate(at, "Stored, but must revalidate");
  } else if (at <= cacheEntry.freshUntil) {
    event = {
      at,
      title: "Fresh cache hit",
      cache: "The cached response is still fresh, so no network request is needed.",
      request: "(none)",
      response: "(none)",
      result: `Use cached body v${cacheEntry.version}`,
    };
  } else if (mode === "stale" && at <= cacheEntry.staleUntil) {
    const servedVersion = cacheEntry.version;
    const background = revalidate(at, "Background revalidation");
    event = {
      at,
      title: "Stale response served immediately",
      cache: "The response is stale, but still inside the stale-while-revalidate window.",
      request: background.request,
      response: background.response,
      result: `Show cached body v${servedVersion} now, refresh cache in the background`,
    };
  } else {
    event = revalidate(at, "Expired cache");
  }

  events.unshift(event);
  events = events.slice(0, 6);
  render();
}

function renderEvent(event) {
  const article = document.createElement("article");
  article.className = "cache-event";
  article.innerHTML = `
    <h3>${event.title} at ${event.at}s</h3>
    <p>${event.cache}</p>
    <div class="cache-columns">
      <div class="cache-box"><strong>Request</strong><pre></pre></div>
      <div class="cache-box"><strong>Response</strong><pre></pre></div>
      <div class="cache-box"><strong>Browser result</strong><pre></pre></div>
    </div>
  `;
  const [request, response, result] = article.querySelectorAll("pre");
  request.textContent = event.request;
  response.textContent = event.response;
  result.textContent = event.result;
  return article;
}

function render() {
  const policy = currentPolicy();
  modeButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
  });
  summary.textContent = policy.header;
  state.replaceChildren();
  const cells = cacheEntry
    ? [
        ["Stored body", `v${cacheEntry.version}`],
        ["ETag", cacheEntry.etag],
        ["Fresh until", `${cacheEntry.freshUntil}s`],
        ["Stale until", `${cacheEntry.staleUntil}s`],
      ]
    : [["Stored body", "empty"]];
  for (const [label, value] of cells) {
    const item = document.createElement("div");
    item.className = "cache-pill";
    item.innerHTML = `<strong></strong><span></span>`;
    item.querySelector("strong").textContent = label;
    item.querySelector("span").textContent = value;
    state.append(item);
  }
  chain.replaceChildren(...events.map(renderEvent));
}

modeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    mode = button.dataset.mode;
    render();
  });
});
visitButtons.forEach((button) => {
  button.addEventListener("click", () => visit(Number(button.dataset.visit)));
});
[maxAgeInput, staleAgeInput, changeAtInput].forEach((input) => {
  input.addEventListener("input", render);
});
resetButton.addEventListener("click", () => {
  cacheEntry = null;
  events = [];
  render();
});

render();
</script>

## What to notice

- `max-age` allows a browser to reuse a response without a request while it is fresh.
- `no-cache` can still store a response, but it must revalidate before reuse.
- `no-store` should not keep a reusable response.
- `immutable` tells the browser that a fresh response will not change at the same URL.
- `stale-while-revalidate` favors speed by showing stale content while refreshing the cache.
