import fs from "node:fs";

const input = fs.readFileSync(0, "utf8");
const words = input.match(/[A-Za-z]+/g) ?? [];
const counts = new Map();

for (const raw of words) {
  const w = raw.toLowerCase();
  counts.set(w, (counts.get(w) ?? 0) + 1);
}

const entries = [...counts.entries()].map(([word, count]) => ({ word, count }));
entries.sort((a, b) => (b.count - a.count) || (a.word < b.word ? -1 : a.word > b.word ? 1 : 0));

const topN = Math.min(entries.length, 10);
let out = "";
for (let i = 0; i < topN; i += 1) {
  out += `${entries[i].count}\t${entries[i].word}\n`;
}
out += "--\n";
out += `total\t${words.length}\n`;
out += `unique\t${entries.length}\n`;
process.stdout.write(out);
