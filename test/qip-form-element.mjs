import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPFormElement = null;

globalThis.HTMLElement = class {};
globalThis.customElements = {
  get() {
    return undefined;
  },
  define(name, elementClass) {
    if (name === "qip-form") {
      QIPFormElement = elementClass;
    }
  },
};

vm.runInThisContext(readFileSync("site/_elements/qip-form.js", "utf8"), {
  filename: "site/_elements/qip-form.js",
});

function source(attributes) {
  return {
    getAttribute(name) {
      return attributes[name] ?? null;
    },
  };
}

test("qip-form loads one explicit Wasm source", async () => {
  const wasm = readFileSync("components/form/form-email-message.wasm");
  const element = new QIPFormElement();
  element.querySelectorAll = (selector) => {
    assert.equal(selector, ":scope > source");
    return [source({ src: "/components/form/form-email-message.wasm", type: "application/wasm" })];
  };

  let fetchedURL = "";
  globalThis.fetch = async (url) => {
    fetchedURL = url;
    return {
      ok: true,
      status: 200,
      async arrayBuffer() {
        return wasm;
      },
    };
  };

  await element._init();
  assert.equal(fetchedURL, "/components/form/form-email-message.wasm");
  assert.equal(typeof element._exports.render, "function");
  assert.equal(element._exports.run, undefined);
});

test("qip-form rejects missing, multiple, and mistyped sources", async () => {
  const missing = new QIPFormElement();
  missing.querySelectorAll = () => [];
  await assert.rejects(missing._init(), /exactly one direct source/);

  const multiple = new QIPFormElement();
  multiple.querySelectorAll = () => [source({}), source({})];
  await assert.rejects(multiple._init(), /exactly one direct source/);

  const mistyped = new QIPFormElement();
  mistyped.querySelectorAll = () => [source({ src: "/form.wasm", type: "text/plain" })];
  await assert.rejects(mistyped._init(), /type must be application\/wasm/);
});
