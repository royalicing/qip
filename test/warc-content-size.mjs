import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasmBytes = await readFile(
  new URL("../recipes/application/warc/25-add-content-size.wasm", import.meta.url),
);

function response(path, contentType, body, status = "200 OK") {
  const payload = Buffer.concat([
    Buffer.from(
      `HTTP/1.1 ${status}\r\n` +
        `Content-Type: ${contentType}\r\n` +
        "ETag: \"stale\"\r\n" +
        "Content-MD5: stale\r\n" +
        "Digest: sha-256=stale\r\n" +
        "X-HTTP-Extension: kept\r\n" +
        `Content-Length: ${body.length}\r\n\r\n`,
    ),
    body,
  ]);
  const recordKey = Buffer.from(path).toString("hex").slice(0, 12).padEnd(12, "0");
  return Buffer.concat([
    Buffer.from(
      "WARC/1.1\r\n" +
        "WARC-Type: response\r\n" +
        `WARC-Target-URI: http://qip.local${path}\r\n` +
        "WARC-Date: 2000-01-01T00:00:00Z\r\n" +
        `WARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-${recordKey}>\r\n` +
        "Content-Type: application/http; msgtype=response\r\n" +
        "WARC-Block-Digest: sha1:STALE\r\n" +
        "WARC-Payload-Digest: sha1:STALE\r\n" +
        "X-WARC-Extension: kept\r\n" +
        `Content-Length: ${payload.length}\r\n\r\n`,
    ),
    payload,
    Buffer.from("\r\n\r\n"),
  ]);
}

async function transform(input) {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const wasm = instance.exports;
  const inputPtr = wasm.input_ptr();
  new Uint8Array(wasm.memory.buffer, inputPtr, input.length).set(input);
  const outputLength = wasm.render(input.length);
  return Buffer.from(new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), outputLength));
}

function firstRecordPayload(warc) {
  const headerEnd = warc.indexOf("\r\n\r\n");
  assert.notEqual(headerEnd, -1);
  const header = warc.subarray(0, headerEnd).toString();
  const length = Number(/^Content-Length: (\d+)$/m.exec(header)?.[1]);
  assert.ok(Number.isSafeInteger(length));
  return warc.subarray(headerEnd + 4, headerEnd + 4 + length);
}

test("qip-content-size resolves later WARC records and rewrites lengths", async () => {
  const page = Buffer.from(
    '<p><qip-content-size hidden src="/tiny.bin">stale</qip-content-size></p>' +
      '<p><qip-content-size src="/large.wasm"></qip-content-size></p>',
  );
  const input = Buffer.concat([
    response("/downloads", "text/html; charset=utf-8", page),
    response("/tiny.bin", "application/octet-stream", Buffer.from("hello")),
    response("/large.wasm", "application/wasm", Buffer.alloc(2301)),
  ]);

  const output = await transform(input);
  const warcHeaderEnd = output.indexOf("\r\n\r\n");
  const warcHeader = output.subarray(0, warcHeaderEnd).toString();
  assert.match(warcHeader, /^WARC\/1\.1$/m);
  assert.match(warcHeader, /^WARC-Date: 2000-01-01T00:00:00Z$/m);
  assert.match(warcHeader, /^WARC-Record-ID: <urn:uuid:/m);
  assert.match(warcHeader, /^X-WARC-Extension: kept$/m);
  assert.doesNotMatch(warcHeader, /^WARC-(?:Block|Payload)-Digest:/m);

  const htmlPayload = firstRecordPayload(output);
  const httpHeaderEnd = htmlPayload.indexOf("\r\n\r\n");
  const httpHeader = htmlPayload.subarray(0, httpHeaderEnd).toString();
  const html = htmlPayload.subarray(httpHeaderEnd + 4);
  assert.equal(Number(/^Content-Length: (\d+)$/m.exec(httpHeader)?.[1]), html.length);
  assert.match(httpHeader, /^X-HTTP-Extension: kept$/m);
  assert.doesNotMatch(httpHeader, /^(?:ETag|Content-MD5|Digest):/m);
  assert.match(html.toString(), /<qip-content-size hidden src="\/tiny\.bin">5 bytes<\/qip-content-size>/);
  assert.match(html.toString(), /<qip-content-size src="\/large\.wasm">2\.30 kB<\/qip-content-size>/);
  assert.doesNotMatch(html.toString(), /stale/);
});

test("qip-content-size traps on an unresolved src", async () => {
  const page = Buffer.from('<qip-content-size src="/missing.wasm"></qip-content-size>');
  await assert.rejects(() => transform(response("/downloads", "text/html", page)), /unreachable/);
});

test("qip-content-size traps when src resolves to HTML", async () => {
  const page = Buffer.from('<qip-content-size src="/other-page"></qip-content-size>');
  const input = Buffer.concat([
    response("/downloads", "text/html", page),
    response("/other-page", "text/html", Buffer.from("<p>Other page</p>")),
  ]);
  await assert.rejects(() => transform(input), /unreachable/);
});

test("qip-content-size ignores placeholders outside HTML", async () => {
  const body = Buffer.from('<qip-content-size src="/missing.wasm"></qip-content-size>');
  const input = response("/plain", "text/plain", body);
  assert.deepEqual(await transform(input), input);
});
