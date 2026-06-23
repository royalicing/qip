import { readFile } from "node:fs/promises";
import {
  contentComponent,
  contentContract,
  contentRecipe,
} from "../site/qip-runner.js";

const text = contentContract({ encoding: "utf-8" });
const markdown = contentContract({ encoding: "utf-8", contentType: "text/markdown" });
const html = contentContract({ encoding: "utf-8", contentType: "text/html" });
const bytes = contentContract({ encoding: "bytes" });

if (!Object.isFrozen(text)) {
  throw new Error("contentContract must return a frozen object");
}

const trim = contentComponent(text, (value) => value.trim(), text);
if (trim(" hi ") !== "hi") {
  throw new Error("JavaScript text component failed");
}

const byteEcho = contentComponent(bytes, (value) => value, bytes);
const echoed = byteEcho(new Uint8Array([1, 2]));
if (!(echoed instanceof Uint8Array) || echoed[1] !== 2) {
  throw new Error("JavaScript byte component failed");
}

const identity = contentRecipe(text, [], text);
if (identity("ok") !== "ok") {
  throw new Error("empty contentRecipe should act as identity");
}

let rejectedBadContract = false;
try {
  contentRecipe({ encoding: "utf8" }, [], text);
} catch {
  rejectedBadContract = true;
}
if (!rejectedBadContract) {
  throw new Error("contentRecipe accepted an invalid content contract");
}

for (const contentType of ["Text/HTML", "text/html; charset=utf-8", " text/html"]) {
  let rejectedBadContentType = false;
  try {
    contentContract({ encoding: "utf-8", contentType });
  } catch {
    rejectedBadContentType = true;
  }
  if (!rejectedBadContentType) {
    throw new Error("contentContract accepted invalid content type " + contentType);
  }
}

const markdownModule = await WebAssembly.compile(
  await readFile("modules/text/markdown/commonmark.0.31.2.wasm"),
);
const pageModule = await WebAssembly.compile(
  await readFile("modules/text/html/html-page-wrap.wasm"),
);

const markdownToHtml = contentComponent(markdown, markdownModule, html);
const htmlPageWrap = contentComponent(html, pageModule, html);
const renderPage = contentRecipe(markdown, [trim, markdownToHtml, htmlPageWrap], html);
const page = renderPage(" # qip ");

if (typeof page !== "string" || !page.includes("<html")) {
  throw new Error("Wasm-backed contentRecipe failed");
}
