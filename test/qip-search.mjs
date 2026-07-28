import test from "node:test";
import assert from "node:assert/strict";

import {
  QIPSearchElement,
  findPrefixPostings,
  nextSuggestionIndex,
  parseTargets,
  rankSearchResults,
  shardName,
  tokenizeQuery,
} from "../site/_elements/qip-search.js";

test("tokenizes unique lowercase ASCII terms", () => {
  assert.deepEqual(tokenizeQuery("Portable components, PORTABLE C"), ["portable", "components", "c"]);
});

test("a first character selects and can fetch its shard", () => {
  const terms = tokenizeQuery("C");
  assert.deepEqual(terms, ["c"]);
  assert.equal(shardName(terms[0]), "c");
});

test("up and down cycle through suggestions", () => {
  assert.equal(nextSuggestionIndex(-1, 3, 1), 0);
  assert.equal(nextSuggestionIndex(-1, 3, -1), 2);
  assert.equal(nextSuggestionIndex(0, 3, 1), 1);
  assert.equal(nextSuggestionIndex(2, 3, 1), 0);
  assert.equal(nextSuggestionIndex(0, 3, -1), 2);
  assert.equal(nextSuggestionIndex(-1, 0, 1), -1);
});

test("focusSuggestion moves focus through rendered links", () => {
  const element = new QIPSearchElement();
  let focused = null;
  const links = Array.from({ length: 3 }, (_, index) => ({
    focus() {
      focused = index;
    },
  }));
  element.results = { querySelectorAll: () => links };

  assert.equal(element.focusSuggestion(1), true);
  assert.equal(focused, 0);
  assert.equal(element.focusSuggestion(1, links[0]), true);
  assert.equal(focused, 1);
  assert.equal(element.focusSuggestion(-1, links[0]), true);
  assert.equal(focused, 2);
});

test("search fetches and presents results after the first character", async () => {
  const element = new QIPSearchElement();
  const loadedShards = [];
  let rendered = [];
  element.input = { value: "C" };
  element.results = {
    dataset: {},
    hidden: true,
    textContent: "",
    setAttribute(name, value) {
      this[name] = value;
    },
  };
  element.searchGeneration = 0;
  element.loadTargets = async () => parseTargets("target,url,label\n1-0,/languages/c,C\n");
  element.loadShard = async (name) => {
    loadedShards.push(name);
    return "term,target,weight\nc,1-0,10\ncomponent,1-0,1\n";
  };
  element.renderResults = (results) => {
    rendered = results;
  };

  await element.search();

  assert.deepEqual(loadedShards, ["c"]);
  assert.equal(rendered[0].url, "/languages/c");
  assert.equal(element.results.dataset.state, "loading");
  assert.equal(element.results["aria-busy"], "true");
});

test("result states distinguish messages from a result list", () => {
  const element = new QIPSearchElement();
  element.results = {
    dataset: {},
    setAttribute(name, value) {
      this[name] = value;
    },
  };

  element.setResultsState("loading", true);
  assert.deepEqual(element.results.dataset, { state: "loading" });
  assert.equal(element.results["aria-busy"], "true");

  element.setResultsState("results");
  assert.deepEqual(element.results.dataset, { state: "results" });
  assert.equal(element.results["aria-busy"], "false");
});

test("finds contiguous prefix postings from the first CSV column", () => {
  const csv =
    "term,target,weight\n" +
    "portable,2-3,12\n" +
    "portability,3-1,4\n" +
    "ports,4-2,2\n" +
    "query,5-0,1\n";
  assert.deepEqual(findPrefixPostings(csv, "porta"), [
    { term: "portable", target: "2-3", weight: 12, exact: false },
    { term: "portability", target: "3-1", weight: 4, exact: false },
  ]);
});

test("ranks an exact one-character term before higher-weight prefix matches", () => {
  const targets = parseTargets(
    "target,url,label\n" +
      "1-0,/languages/c,C language\n" +
      "2-0,/components,Components\n" +
      "3-0,/architecture,Architecture\n",
  );
  const postings = findPrefixPostings(
    "term,target,weight\n" +
      "c,1-0,2\n" +
      "c,3-0,1\n" +
      "component,2-0,100\n" +
      "components,3-0,200\n",
    "c",
  );
  const results = rankSearchResults([postings], targets);
  assert.equal(results[0].url, "/languages/c");
  assert.equal(results[0].exactTerms, 1);
  assert.equal(results[0].exactScore, 2);
});

test("parses quoted target labels without treating markup as HTML", () => {
  const targets = parseTargets(
    'target,url,label\n1-0,/,"QIP, components"\n1-1,/#canvas,"QIP — <canvas>"\n',
  );
  assert.equal(targets.get("1-0").label, "QIP, components");
  assert.equal(targets.get("1-1").label, "QIP — <canvas>");
});

test("groups terms across sections and links the page target", () => {
  const targets = parseTargets(
    "target,url,label\n" +
      "2-0,/docs/abc,ABC Docs\n" +
      "2-3,/docs/abc#portable,ABC Docs — Portable\n" +
      "2-5,/docs/abc#components,ABC Docs — Components\n",
  );
  const results = rankSearchResults(
    [
      [{ term: "portable", target: "2-3", weight: 12 }],
      [{ term: "component", target: "2-5", weight: 14 }],
    ],
    targets,
  );
  assert.equal(results[0].target, "2-0");
  assert.equal(results[0].matchedTerms, 2);
  assert.equal(results[0].score, 26);
});

test("links a fragment when one section matches every term", () => {
  const targets = parseTargets(
    "target,url,label\n" +
      "2-0,/docs/abc,ABC Docs\n" +
      "2-3,/docs/abc#portable,ABC Docs — Portable\n",
  );
  const results = rankSearchResults(
    [
      [{ term: "portable", target: "2-3", weight: 12 }],
      [{ term: "webassembly", target: "2-3", weight: 5 }],
    ],
    targets,
  );
  assert.equal(results[0].target, "2-3");
  assert.equal(results[0].url, "/docs/abc#portable");
});

test("ranks distinct query-term coverage before accumulated weight", () => {
  const targets = parseTargets(
    "target,url,label\n" +
      "1-0,/one,One\n" +
      "2-0,/two,Two\n",
  );
  const results = rankSearchResults(
    [
      [
        { term: "portable", target: "1-0", weight: 100 },
        { term: "portable", target: "2-0", weight: 2 },
      ],
      [{ term: "component", target: "2-0", weight: 2 }],
    ],
    targets,
  );
  assert.equal(results[0].target, "2-0");
});
