import { readFile } from "node:fs/promises";
import {
  contentComponent,
  contentRecipe,
  contentTypeBytes,
  contentTypeUTF8,
} from "../site/qip-runner.js";

const text = contentTypeUTF8();
const markdown = contentTypeUTF8("text/markdown");
const html = contentTypeUTF8("text/html");
const bytes = contentTypeBytes();
const bmp = contentTypeBytes("image/bmp");

if (!Object.isFrozen(text) || !Object.isFrozen(bmp)) {
  throw new Error("content type constructors must return frozen objects");
}
if (
  text.contentType !== undefined ||
  bmp.contentType !== "image/bmp"
) {
  throw new Error("content type constructors returned incorrect contracts");
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
  contentRecipe({}, [], text);
} catch {
  rejectedBadContract = true;
}
if (!rejectedBadContract) {
  throw new Error("contentRecipe accepted a plain object as a content contract");
}

const forgedComponent = (value) => value;
forgedComponent.input = {};
forgedComponent.output = {};
let rejectedForgedComponent = false;
try {
  contentRecipe(text, [forgedComponent], text);
} catch {
  rejectedForgedComponent = true;
}
if (!rejectedForgedComponent) {
  throw new Error("contentRecipe accepted plain-object component contracts");
}

for (const constructor of [contentTypeUTF8, contentTypeBytes]) {
  for (const contentType of ["Text/HTML", "text/html; charset=utf-8", " text/html"]) {
    let rejectedBadContentType = false;
    try {
      constructor(contentType);
    } catch {
      rejectedBadContentType = true;
    }
    if (!rejectedBadContentType) {
      throw new Error(constructor.name + " accepted invalid content type " + contentType);
    }
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
