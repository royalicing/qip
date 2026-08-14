# qip-router

`qip-router` serves a QIP content directory with Node.js. It reads content,
recipes, component assets, and custom-element modules directly from the
filesystem, and runs QIP components with Node's WebAssembly runtime.

Documentation: <https://qip.dev/docs/router>

```sh
npx qip-router dev ./site
```

The package has no runtime dependencies. It requires Node.js 22 or newer.

## Commands

```sh
qip-router dev ./site
qip-router get ./site /docs/router
qip-router head ./site /docs/router
qip-router list ./site
qip-router warc ./site -o site.warc
```

Project directories are discovered below the content root:

```text
site/
  _recipes/
  _components/
  _elements/
  index.md
```

They can also be supplied separately:

```sh
qip-router dev ./site \
  --recipes ./recipes \
  --components ./components \
  --elements ./elements
```

The development server listens on `127.0.0.1:4000` by default. Existing
content files are read for each request. A browser hard refresh reloads the
route table and recipe modules, so newly added files and changed recipes take
effect without restarting the process.

## JavaScript API

The executable is also an ES module:

```js
import { createQIPRouter } from "qip-router";

const router = await createQIPRouter({ contentRoot: "./site" });
const server = await router.listen({ port: 4000 });
```

`router.fetch(request)` returns a standard Fetch API `Response`, which lets QIP
Router mount inside Hono, Workers-style runtimes, and other Fetch-native hosts.
`router.get(path)` and `router.head(path)` resolve requests without opening a
network socket and return `{ status, headers, body }`. `router.head(path)` sets
HEAD headers such as `content-length`, but its `body` is an empty `Uint8Array`.
`router.resolve(method, path)` is available when the method is dynamic.
`router.warc()` returns the transformed full-site WARC as a `Uint8Array`.

```js
app.all("/docs/*", async (c) => {
  const url = new URL(c.req.url);
  url.pathname = url.pathname.slice("/docs".length) || "/";
  return router.fetch(new Request(url, c.req.raw));
});
```

## Current boundary

The Node router implements content recipes, raw Markdown routes, component
and element assets, Kindred Route WARC transforms, and lazy full-site-derived
routes. Its page and full-site WARC output are tested byte-for-byte against
the Go router.

Recipe execution is synchronous WebAssembly. A component that does not return
can therefore block the Node process. Use the Go router when execution
timeouts are required; a future Node isolation layer can use worker threads
without adding a package dependency.
