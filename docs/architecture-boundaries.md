# Architecture And Boundaries

QIP puts a narrow byte boundary inside a normal application.

The host stays responsible for routing, storage, auth, product workflow, and platform APIs. QIP components do small deterministic work behind a WebAssembly boundary: the host gives them bytes, they return bytes, and they do not get ambient access to the machine around them.

This page compares that shape with traditional server rendering and Next.js-style rendering, then looks at each through a security boundary lens.

## Legend

```text
[trusted]       code that can use app privileges
[sandboxed]     code behind a narrower runtime boundary
-->             bytes, events, or HTTP messages passed explicitly
xxx             ambient access that code can use directly
```

Ambient access means things like filesystem, network, environment variables, secrets, clocks, process globals, database clients, or installed packages.

## Traditional Web Page

A traditional server-rendered page usually has one main application trust boundary.

```text
Browser
  |
  | HTTP request
  v
+----------------------------------------------------------+
| [trusted] Web app process                                |
|                                                          |
|  router -> controller -> template -> HTML response        |
|                                                          |
|  app code xxx database                                   |
|  app code xxx filesystem                                 |
|  app code xxx environment/secrets                        |
|  app code xxx package graph                              |
+----------------------------------------------------------+
  |
  | HTML/CSS/JS
  v
Browser sandbox
```

This model is direct and easy to deploy. The tradeoff is that templates, helpers, plugins, and dependencies often run with the same authority as the app process. If a library is compromised, or generated code is wrong, it may be able to do whatever the app process can do.

The browser is still a real sandbox, but the server-side rendering work happens before the browser boundary.

## Next.js-Style Rendering

Next.js splits rendering across build time, server time, and browser time. The exact path depends on route mode, caching, server components, client components, actions, and API routes, but the broad shape looks like this:

```text
Build time
------------------------------------------------------------
source + npm packages + config + env
  |
  v
+----------------------------------------------------------+
| [trusted] framework/build process                         |
|                                                          |
|  compile routes, bundles, assets, server code             |
|  build code xxx filesystem                               |
|  build code xxx package graph                            |
|  build code xxx environment                              |
+----------------------------------------------------------+

Request time
------------------------------------------------------------
Browser
  |
  | HTTP request
  v
+----------------------------------------------------------+
| [trusted] Next/server runtime                             |
|                                                          |
|  route -> server render/data/API/action -> response       |
|                                                          |
|  server code xxx database                                |
|  server code xxx filesystem                              |
|  server code xxx environment/secrets                     |
|  server code xxx package graph                           |
+----------------------------------------------------------+
  |
  | HTML + data + JS bundles
  v
+----------------------------------------------------------+
| Browser sandbox                                           |
|                                                          |
|  [sandboxed by browser] client components + hydrated UI   |
|  browser code xxx user page state                         |
|  browser code xxx allowed web APIs                        |
+----------------------------------------------------------+
```

This model is powerful because one framework coordinates routing, rendering, caching, data loading, and client hydration. It also means a lot of application behavior sits inside the framework and package graph. The server-side parts are trusted application code. They need access to secrets and databases, so they cannot be treated as isolated transforms.

The browser/client split is useful, but it is not the same as isolating a server-side content transform from the server process.

React Server Components are a useful example of this boundary. In December 2025, React disclosed [CVE-2025-55182](https://react.dev/blog/2025/12/03/critical-security-vulnerability-in-react-server-components), an unauthenticated remote-code-execution vulnerability in React Server Components. Next.js documented the downstream App Router impact as [CVE-2025-66478](https://nextjs.org/blog/CVE-2025-66478). The lesson is not that server components are uniquely bad. The lesson is that server-side rendering protocols run inside the trusted server boundary. When that boundary is crossed incorrectly, the blast radius can include application secrets, database access, and the host process.

## Browser Trust Boundaries

Most web security bugs come from confusing three different things:

- Who sent this request?
- Which origin is allowed to read the response?
- What code is allowed to run inside this origin?

Cookies, sessions, bearer tokens, origins, HTML, and JavaScript each sit on different parts of that map.

```text
User browser
  |
  | request to https://app.example
  | browser may attach cookies for app.example
  v
+----------------------------------------------------------+
| [trusted] app.example server                             |
|                                                          |
|  session cookie -> account identity                      |
|  CSRF token/origin checks -> request intent              |
|  HTML escaping/sanitizing -> code/content boundary        |
+----------------------------------------------------------+
  |
  | response for app.example
  v
+----------------------------------------------------------+
| Browser origin: https://app.example                      |
|                                                          |
|  JS here can call app.example APIs                       |
|  JS here can read same-origin DOM and non-HttpOnly tokens |
|  browser enforces limits against other origins            |
+----------------------------------------------------------+
```

The browser does a lot, but it does not know which POST request the user intended. It also cannot tell whether a CMS field was meant to be text, trusted HTML, or executable script unless the application keeps those boundaries clear.

## XSS: Untrusted Content Becomes App Code

Cross-site scripting happens when untrusted content is rendered as active HTML or JavaScript inside a trusted origin.

```text
CMS field, user comment, Markdown, imported feed
  |
  | treated as trusted HTML
  v
+----------------------------------------------------------+
| Browser origin: https://app.example                      |
|                                                          |
|  <script> or event handler now runs as app.example        |
|                                                          |
|  can read DOM                                            |
|  can call same-origin APIs                               |
|  can read tokens stored in JS-visible storage             |
|  can submit requests with existing cookies                |
+----------------------------------------------------------+
```

An `HttpOnly` cookie helps because JavaScript cannot read it directly. It does not stop injected JavaScript from sending same-origin requests that automatically include that cookie. A bearer token in `localStorage`, a global JS variable, or a page-embedded data blob is usually easier for XSS to steal.

The practical rule: untrusted content should stay text until a sanitizer or renderer deliberately turns it into a smaller safe subset. Markdown is not automatically safe. CMS HTML is not automatically safe. QIP output is not automatically safe.

## CSRF/XSRF: Surprise Requests Borrow A Session

Cross-site request forgery happens when another site causes the browser to send a request that carries the user's existing authority.

```text
https://evil.example
  |
  | link, image, form, script-created navigation
  v
User browser
  |
  | request to https://app.example
  | cookies may be attached by the browser
  v
+----------------------------------------------------------+
| [trusted] app.example server                             |
|                                                          |
|  "this user has a session" is not enough                 |
|  server must also ask "did the user intend this action?" |
+----------------------------------------------------------+
```

The attacker usually cannot read the response across origins. That is still enough if the request changes state: publish, delete, transfer, invite, rotate, buy, subscribe.

Use `SameSite` cookies, CSRF tokens, method discipline, origin checks, and idempotent GET routes. These are application boundaries, not rendering boundaries.

## CMS And User-Generated Content

A CMS is convenient because non-developers can change production content. It is also a trust decision.

```text
CMS editor / user / imported content
  |
  | content bytes
  v
+----------------------------------------------------------+
| [trusted?] content store                                 |
+----------------------------------------------------------+
  |
  | render as text, sanitized HTML, or trusted HTML?
  v
Browser origin
```

Treat CMS content as a data source first. Decide what each field is allowed to contain:

- Plain text is safest.
- Markdown needs a renderer and usually an HTML sanitizer.
- Sanitized HTML needs a clear allowed element/attribute policy.
- Trusted HTML means the author can affect the page as code and should be treated like a developer.
- User-generated content should not be rendered as same-origin active HTML.

QIP can help with the transform part. A QIP Markdown renderer or sanitizer can run without filesystem, network, environment, or secret access. That limits what a bad renderer can do to the host. It does not mean the rendered HTML is safe to mount into a privileged origin.

## Confused Deputy

A confused deputy bug happens when trusted code is tricked into using its authority for less-trusted input.

```text
untrusted input
  |
  | "please do this"
  v
+----------------------------------------------------------+
| [trusted] app/server/browser with real authority          |
|                                                          |
|  has cookies, secrets, filesystem, network, database      |
|  accidentally spends that authority for the attacker      |
+----------------------------------------------------------+
```

CSRF is one version: the browser has the user's cookies, and an attacker tries to borrow them for an unwanted action. Server-side request forgery is another: the server has network access, and attacker-controlled input chooses where it points. Template injection and rendering RCE follow the same pattern when a renderer with app privileges is made to execute content as code.

QIP is designed to make the deputy smaller. The component does not get ambient authority by default, so there is much less authority for attacker-controlled input to borrow.

## Capabilities Instead Of Ambient Context

Capability-based security starts with a simple rule: code can only use what it has been explicitly given.

Many application tools assume global context. A helper can read process environment. A plugin can import a package. A server component can call application code. A template extension may reach the filesystem or network because it is running inside the app process.

QIP is on the strict side of this spectrum. A component cannot reach out to discover context. The host passes bytes in and the component returns bytes out. If the component needs a setting, pass it as a uniform or include it in the input. If it needs database data, the app should query the database and pass only the relevant bytes.

```text
ambient model:       code -> reaches out for context
capability model:    host -> passes explicit input -> code
QIP default:         host -> bytes/uniforms/events -> component -> bytes
```

These explicit boundaries are easy to reason about, audit, test, and review.

## CSP And Sandboxed Previews

Content Security Policy is a browser-side blast-radius control. It can restrict where scripts, images, styles, frames, and connections may come from. A good CSP does not replace escaping, sanitizing, or careful content modeling, but it gives the browser a policy to enforce when something slips.

Sandboxed iframes are another useful boundary. Any framework can add `sandbox`, and QIP should use it where it renders untrusted preview HTML. A sandboxed preview is a place to inspect output without immediately granting it the full authority of the app origin.

```text
app origin
  |
  | preview bytes
  v
<iframe sandbox>
  |
  | rendered output with reduced browser powers
  v
preview document
```

Use CSP and iframe sandboxing as browser boundaries. Use QIP as the transform boundary before the browser sees the bytes.

## Script Tags And Growing Sandboxes

Loading JavaScript from a server is a different trust decision.

If you load JavaScript with `<script src="...">`, there is no small component boundary around that script. It runs as page code. It can allocate memory until the browser stops it. It can start more network requests. It can load more code. It runs in a browser sandbox, but the sandbox can grow in size and reach out to fetch more of what it wants.

That is often intentional. Analytics and tracking scripts are added to help product and marketing teams understand behavior. The tradeoff is that the script is not just data. It is code running inside your page's authority.

```text
<script src="https://analytics.example/script.js">
  |
  v
+----------------------------------------------------------+
| Browser origin: https://app.example                      |
|                                                          |
|  third-party script runs as page code                    |
|  can inspect DOM                                         |
|  can send network requests                               |
|  can allocate memory until browser/runtime limits         |
|  can load more code                                      |
+----------------------------------------------------------+
```

QIP is meant to sit on the stricter side of this spectrum. A component should not assume it can read global page context, discover tokens, call network APIs, or grow into a larger runtime. The host passes input explicitly and reads output explicitly.

The CLI and browser custom elements now expose that boundary as policy. `qip run`, `qip bench`, and `qip image` can reject modules with `--max-memory <bytes>` and `--fixed-memory`. `<qip-preview>` and `<qip-play>` can do the same before browser compilation with `max-memory="<bytes>"` and `fixed-memory`.

Those checks are opt-in. That is deliberate for now: current components do not use `memory.grow`, but some older artifacts still need explicit memory maxima before a max-memory rule can become painless by default.

## How WebAssembly Changes The Shape

WebAssembly is not HTML and it is not JavaScript. A Wasm module gets linear memory and imported functions. If the host does not import filesystem, network, DOM, clock, or secret access, the module cannot call those things directly.

```text
[trusted] browser JS or server host
  |
  | imports decide capabilities
  v
+----------------------------------------------------------+
| [sandboxed] WebAssembly module                           |
|                                                          |
|  can compute over memory                                 |
|  cannot reach host APIs without imports                  |
+----------------------------------------------------------+
```

QIP narrows this further. A QIP component is not given WASI by default. It is not given custom host imports by the current runtime. The normal interface is input bytes, optional uniforms/events, `render(input_size)`, and output bytes. Instead of assuming global context, QIP makes context an explicit input.

That means QIP is a useful place to run code you want to review as a transform instead of trusting as application code. It is especially useful for AI-generated components, content transforms, validators, and renderers that should not inherit the app's filesystem, network, database, or secret access.

## QIP Component Pipeline

QIP makes the small transform a separate boundary.

```text
[trusted] host app, qip run, qip dev, qip router, native app, CI
  |
  | explicit input bytes
  v
+------------------+      +------------------+      +------------------+
| [sandboxed]      |      | [sandboxed]      |      | [sandboxed]      |
| component A      | ---> | component B      | ---> | component C      |
|                  |      |                  |      |                  |
| no filesystem    |      | no filesystem    |      | no filesystem    |
| no network       |      | no network       |      | no network       |
| no env/secrets   |      | no env/secrets   |      | no env/secrets   |
| no package graph |      | no package graph |      | no package graph |
+------------------+      +------------------+      +------------------+
  ^                                                     |
  |                                                     v
  +---------------- explicit output bytes --------------+
```

Each stage receives only the bytes, uniforms, or events the host deliberately passes in. A Markdown renderer does not get a database handle. A QR-code generator does not get network access. A generated validator does not get environment variables or local files.

The host is still trusted. The difference is that the component is not handed the host's privileges just because it is useful code.

## QIP Inside An Existing App

QIP is not trying to replace the application. It fits at the places where a small piece of work should be portable, deterministic, or easier to review.

```text
+----------------------------------------------------------+
| [trusted] product app                                    |
|                                                          |
|  routes, auth, metrics, logging, DB queries, UI state     |
|       |                                                  |
|       | explicit bytes                                   |
|       v                                                  |
|    +-----------------------------------------------+     |
|    | [sandboxed] QIP component or recipe            |     |
|    |                                               |     |
|    | markdown -> HTML                              |     |
|    | SVG -> bitmap                                 |     |
|    | URL -> QR SVG                                 |     |
|    | HTML -> accessibility facts                   |     |
|    +-----------------------------------------------+     |
|       |                                                  |
|       | explicit bytes                                   |
|       v                                                  |
|  app decides where the output goes                       |
+----------------------------------------------------------+
```

The application can weave normal code between QIP stages. For example, it can log a metric, run a database query, choose a component, pass bytes into QIP, then store or render the output. QIP should not become the whole app.

## QIP Router

QIP Router uses the same boundary, but applies it to routed content.

```text
site/
  index.md
  docs/security.md
  _recipes/text/markdown/10-render.wasm
  _recipes/text/markdown/20-wrap.wasm

Request: /docs/security
  |
  v
+----------------------------------------------------------+
| [trusted] qip router                                     |
|                                                          |
|  resolve path -> read source bytes -> choose recipes      |
+----------------------------------------------------------+
  |
  | docs/security.md bytes
  v
+------------------+      +------------------+
| [sandboxed]      |      | [sandboxed]      |
| 10-render.wasm   | ---> | 20-wrap.wasm     |
| Markdown -> HTML |      | HTML -> page     |
+------------------+      +------------------+
  |
  | response bytes
  v
Browser
```

The router can read files because it is the host. Recipe components cannot read the site tree directly. They only see the current response bytes unless the host passes a larger format, such as `application/warc`, into an archive-level recipe.

## Whole-Site Recipes

Some work needs the whole routed site, not one page at a time. QIP uses WARC as the explicit boundary format for that.

```text
[trusted] qip router
  |
  | routed site as application/warc
  v
+-----------------------------------------------+
| [sandboxed] application/warc recipe            |
|                                               |
| check links, add sitemap, add redirects,       |
| rewrite archive records                        |
+-----------------------------------------------+
  |
  | updated application/warc
  v
[trusted] host writes tar, deploys, or inspects output
```

The component still does not get filesystem or network access. The host chooses to provide a whole archive as input bytes.

## Security Boundary View

QIP separates three questions that are often blended together:

- What can the host process do?
- What bytes are passed into this component?
- What can this component do without asking the host?

In QIP, the answer to the third question should be boring: it can compute over its linear memory and exported functions. It cannot open a socket, read `~/.ssh`, inspect `process.env`, install a package, or call a database unless the host gives it a custom capability. The current `qip` runtime does not provide WASI or custom host imports to content components.

That boundary is useful for unreviewed or AI-generated code. The code may still be wrong. It may still produce unsafe HTML, invalid JSON, or a bad image. But it should not be able to escape the input/output contract and rummage through the host.

For browser security, keep the distinction sharp:

- QIP can reduce the host privileges of the code doing a transform.
- QIP cannot make untrusted HTML safe just because the HTML was produced by Wasm.
- QIP cannot decide whether a session-bearing request was intentional.
- QIP can be one stage in a larger safety pipeline, such as render Markdown, sanitize HTML, validate links, then embed output in a sandboxed preview or carefully escaped app view.

## What Still Needs Review

The boundary is not a substitute for all review.

- Review what bytes the host passes in.
- Review where output bytes are used.
- Treat component output as untrusted until the next boundary validates or escapes it.
- Do not mount untrusted HTML into a privileged origin without a sanitizer or sandboxed container.
- Keep CMS and user-generated content policies explicit: text, Markdown, sanitized HTML, or trusted HTML.
- Keep CSRF/XSRF defenses on state-changing routes; a component boundary does not replace request-intent checks.
- Pin component artifacts for production use.
- Keep memory and timeout limits tight enough for the job.
- Use `qip comply` when a behavior can be checked against a separate spec.
- Use `qip bench` when performance matters.

The important shift is scope. A bad component should be a bad transform, not a bad transform with filesystem, network, package, and secret access.

## Short Comparison

| Model | Main unit | Good at | Security shape |
| --- | --- | --- | --- |
| Traditional web app | app process | simple request -> response rendering | server code and dependencies share app authority |
| Next.js-style app | framework-coordinated app | routing, caching, server/client rendering, hydration | browser code is sandboxed; server/build code is trusted app code |
| QIP | small component or recipe stage | deterministic transforms that run inside many apps | component sees explicit bytes and runs without ambient host access |

QIP is not a better Next.js or a smaller traditional web framework. It is a different boundary. Use it when the valuable part is a portable, deterministic piece of work that should not inherit the full authority of the app around it.
