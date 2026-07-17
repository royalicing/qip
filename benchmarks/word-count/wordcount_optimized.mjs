import fs from "node:fs";

const input = fs.readFileSync(0, "utf8");
const counts = new Map();
let total = 0;
let token = "";

for (let i = 0; i <= input.length; i += 1) {
  const ch = i < input.length ? input.charCodeAt(i) : 0;
  const isLetter = (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90);
  if (isLetter) {
    const lower = ch >= 65 && ch <= 90 ? ch + 32 : ch;
    token += String.fromCharCode(lower);
    continue;
  }
  if (token.length > 0) {
    counts.set(token, (counts.get(token) ?? 0) + 1);
    total += 1;
    token = "";
  }
}

const entries = [...counts.entries()].map(([word, count]) => ({ word, count }));
entries.sort((a, b) => (b.count - a.count) || (a.word < b.word ? -1 : a.word > b.word ? 1 : 0));

const topN = Math.min(entries.length, 10);
let out = "";
for (let i = 0; i < topN; i += 1) {
  out += `${entries[i].count}\t${entries[i].word}\n`;
}
out += "--\n";
out += `total\t${total}\n`;
out += `unique\t${entries.length}\n`;
process.stdout.write(out);
