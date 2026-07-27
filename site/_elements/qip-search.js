const SEARCH_ROOT = "/search/v1/";
const HTMLElementBase = globalThis.HTMLElement ?? class {};

export function tokenizeQuery(value) {
  return [...new Set(value.toLowerCase().match(/[a-z0-9_]+/g) ?? [])];
}

export function shardName(term) {
  const first = term[0] ?? "_";
  if (first >= "a" && first <= "z") return first;
  if (first >= "0" && first <= "9") return "0";
  return "_";
}

export function parseCSV(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
    } else if (character === '"' && field.length === 0) {
      quoted = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field.endsWith("\r") ? field.slice(0, -1) : field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += character;
    }
  }

  if (field.length > 0 || row.length > 0) {
    row.push(field.endsWith("\r") ? field.slice(0, -1) : field);
    rows.push(row);
  }
  return rows;
}

export function parseTargets(csv) {
  const targets = new Map();
  for (const [target, url, label] of parseCSV(csv).slice(1)) {
    if (target && url && label) targets.set(target, { target, url, label });
  }
  return targets;
}

export function findPrefixPostings(csv, prefix) {
  const postings = [];
  let lineStart = csv.indexOf(`\n${prefix}`);
  if (lineStart < 0) return postings;
  lineStart += 1;

  while (lineStart < csv.length) {
    let lineEnd = csv.indexOf("\n", lineStart);
    if (lineEnd < 0) lineEnd = csv.length;
    const line = csv.slice(lineStart, lineEnd);
    const firstComma = line.indexOf(",");
    if (firstComma < 0) break;
    const term = line.slice(0, firstComma);
    if (!term.startsWith(prefix)) break;
    const secondComma = line.indexOf(",", firstComma + 1);
    if (secondComma < 0) break;
    const target = line.slice(firstComma + 1, secondComma);
    const weight = Number.parseInt(line.slice(secondComma + 1), 10);
    if (target && Number.isSafeInteger(weight)) postings.push({ term, target, weight, exact: term === prefix });
    lineStart = lineEnd + 1;
  }
  return postings;
}

function pageID(target) {
  const separator = target.indexOf("-");
  return separator < 0 ? target : target.slice(0, separator);
}

export function rankSearchResults(postingsByQueryTerm, targets, limit = 8) {
  const pages = new Map();

  postingsByQueryTerm.forEach((postings, queryIndex) => {
    for (const posting of postings) {
      const page = pageID(posting.target);
      let pageMatch = pages.get(page);
      if (!pageMatch) {
        pageMatch = { weights: [], exactWeights: [], sections: new Map() };
        pages.set(page, pageMatch);
      }
      pageMatch.weights[queryIndex] = Math.max(pageMatch.weights[queryIndex] ?? 0, posting.weight);
      if (posting.exact) {
        pageMatch.exactWeights[queryIndex] = Math.max(pageMatch.exactWeights[queryIndex] ?? 0, posting.weight);
      }

      let sectionMatch = pageMatch.sections.get(posting.target);
      if (!sectionMatch) {
        sectionMatch = { weights: [], exactWeights: [] };
        pageMatch.sections.set(posting.target, sectionMatch);
      }
      sectionMatch.weights[queryIndex] = Math.max(sectionMatch.weights[queryIndex] ?? 0, posting.weight);
      if (posting.exact) {
        sectionMatch.exactWeights[queryIndex] = Math.max(
          sectionMatch.exactWeights[queryIndex] ?? 0,
          posting.weight,
        );
      }
    }
  });

  const results = [];
  for (const [page, match] of pages) {
    const matchedTerms = match.weights.filter((weight) => weight > 0).length;
    const exactTerms = match.exactWeights.filter((weight) => weight > 0).length;
    const exactScore = match.exactWeights.reduce((sum, weight) => sum + (weight ?? 0), 0);
    const score = match.weights.reduce((sum, weight) => sum + (weight ?? 0), 0);
    let selectedTarget = `${page}-0`;
    let selectedCoverage = 0;
    let selectedExactTerms = 0;
    let selectedExactScore = 0;
    let selectedScore = 0;

    for (const [target, section] of match.sections) {
      const coverage = section.weights.filter((weight) => weight > 0).length;
      const sectionExactTerms = section.exactWeights.filter((weight) => weight > 0).length;
      const sectionExactScore = section.exactWeights.reduce((sum, weight) => sum + (weight ?? 0), 0);
      const sectionScore = section.weights.reduce((sum, weight) => sum + (weight ?? 0), 0);
      if (
        coverage === matchedTerms &&
        (coverage > selectedCoverage ||
          (coverage === selectedCoverage && sectionExactTerms > selectedExactTerms) ||
          (coverage === selectedCoverage &&
            sectionExactTerms === selectedExactTerms &&
            sectionExactScore > selectedExactScore) ||
          (coverage === selectedCoverage &&
            sectionExactTerms === selectedExactTerms &&
            sectionExactScore === selectedExactScore &&
            sectionScore > selectedScore))
      ) {
        selectedTarget = target;
        selectedCoverage = coverage;
        selectedExactTerms = sectionExactTerms;
        selectedExactScore = sectionExactScore;
        selectedScore = sectionScore;
      }
    }

    const metadata = targets.get(selectedTarget) ?? targets.get(`${page}-0`);
    if (metadata) results.push({ ...metadata, matchedTerms, exactTerms, exactScore, score });
  }

  return results
    .sort(
      (left, right) =>
        right.matchedTerms - left.matchedTerms ||
        right.exactTerms - left.exactTerms ||
        right.exactScore - left.exactScore ||
        right.score - left.score ||
        left.label.localeCompare(right.label),
    )
    .slice(0, limit);
}

export class QIPSearchElement extends HTMLElementBase {
  connectedCallback() {
    this.input = this.querySelector('input[type="search"]');
    this.results = this.querySelector(".qip-search-results");
    this.form = this.querySelector("form");
    if (!this.input || !this.results || !this.form) return;

    this.shards = new Map();
    this.searchGeneration = 0;
    this.input.addEventListener("input", () => this.search());
    this.input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        this.input.value = "";
        this.hideResults();
      } else if (event.key === "ArrowDown") {
        const first = this.results.querySelector("a");
        if (first) {
          event.preventDefault();
          first.focus();
        }
      }
    });
    this.form.addEventListener("submit", (event) => {
      const first = this.results.querySelector("a");
      if (!first) return;
      event.preventDefault();
      first.click();
    });
    document.addEventListener("click", (event) => {
      if (!this.contains(event.target)) this.hideResults();
    });
  }

  hideResults() {
    this.results.hidden = true;
    this.results.replaceChildren();
  }

  async fetchText(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error(`search asset returned HTTP ${response.status}`);
    return response.text();
  }

  loadTargets() {
    if (!this.targetsPromise) {
      this.targetsPromise = this.fetchText(`${SEARCH_ROOT}targets.csv`).then(parseTargets);
    }
    return this.targetsPromise;
  }

  loadShard(name) {
    if (!this.shards.has(name)) {
      this.shards.set(name, this.fetchText(`${SEARCH_ROOT}index/${name}.csv`));
    }
    return this.shards.get(name);
  }

  async search() {
    const generation = ++this.searchGeneration;
    const terms = tokenizeQuery(this.input.value);
    if (terms.length === 0) {
      this.hideResults();
      return;
    }

    this.results.hidden = false;
    this.results.textContent = "Searching…";
    try {
      const [targets, ...shardTexts] = await Promise.all([
        this.loadTargets(),
        ...terms.map((term) => this.loadShard(shardName(term))),
      ]);
      if (generation !== this.searchGeneration) return;
      const postings = terms.map((term, index) => findPrefixPostings(shardTexts[index], term));
      this.renderResults(rankSearchResults(postings, targets));
    } catch (error) {
      if (generation !== this.searchGeneration) return;
      this.results.textContent = "Search is unavailable.";
      console.error(error);
    }
  }

  renderResults(results) {
    this.results.replaceChildren();
    if (results.length === 0) {
      this.results.textContent = "No matching pages.";
      return;
    }
    const list = document.createElement("ol");
    for (const result of results) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = result.url;
      link.textContent = result.label;
      item.append(link);
      list.append(item);
    }
    this.results.append(list);
  }
}

if (globalThis.customElements && !customElements.get("qip-search")) {
  customElements.define("qip-search", QIPSearchElement);
}
