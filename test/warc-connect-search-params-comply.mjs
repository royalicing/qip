import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const complianceBytes = await readFile(
  new URL("../compliance/warc-connect-search-params.comply.wasm", import.meta.url),
);

registerGenericComplianceTests(test, complianceBytes, {
  curatedCount: 10,
  expectSeedVariation: false,
});

function firstResponse(warc) {
  const warcHeaderEnd = warc.indexOf("\r\n\r\n");
  assert.notEqual(warcHeaderEnd, -1);
  const warcHeader = warc.subarray(0, warcHeaderEnd).toString();
  const target = /^WARC-Target-URI: (.+)\r$/m.exec(warcHeader)?.[1];
  assert.ok(target);

  const payloadLength = Number(/^Content-Length: (\d+)\r?$/m.exec(warcHeader)?.[1]);
  assert.ok(Number.isSafeInteger(payloadLength));
  const payload = warc.subarray(warcHeaderEnd + 4, warcHeaderEnd + 4 + payloadLength);
  const httpHeaderEnd = payload.indexOf("\r\n\r\n");
  assert.notEqual(httpHeaderEnd, -1);
  const httpHeader = payload.subarray(0, httpHeaderEnd).toString();
  const bodyLength = Number(/^Content-Length: (\d+)\r?$/m.exec(httpHeader)?.[1]);
  assert.ok(Number.isSafeInteger(bodyLength));
  const body = payload.subarray(httpHeaderEnd + 4);
  assert.equal(body.length, bodyLength);
  return { target, body };
}

test("corpus exposes request targets and documents for host adapters", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  assert.equal(cases.length, 10);

  const firstInput = firstResponse(cases[0].input);
  const firstExpected = firstResponse(cases[0].expected);
  assert.equal(firstInput.target, "https://example.test/page?language=fr");
  assert.equal(firstExpected.target, firstInput.target);
  assert.match(firstInput.body.toString(), /value="en"/);
  assert.match(firstExpected.body.toString(), /value="fr" data-qip-fallback="en"/);

  for (const fixture of cases) {
    const input = firstResponse(fixture.input);
    const expected = firstResponse(fixture.expected);
    assert.equal(expected.target, input.target);
  }
});

test("corpus defines first-value query semantics and fallback restoration", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);

  const duplicate = firstResponse(cases[5].expected).body.toString();
  assert.match(duplicate, /value="fr" data-qip-fallback="en"/);

  const repeatedRequest = firstResponse(cases[6].expected).body.toString();
  assert.match(repeatedRequest, /value="de" data-qip-fallback="en"/);

  const restored = firstResponse(cases[7].expected).body.toString();
  assert.match(restored, /value="en" data-qip-fallback="en"/);
});
