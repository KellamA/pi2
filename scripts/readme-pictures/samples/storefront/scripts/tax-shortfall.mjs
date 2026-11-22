// How much tax Canadian orders were short, by province (sample data).
const rows = [["ON", 141, 1018.40, 2647.84], ["QC", 64, 412.65, 1235.89], ["BC", 52, 331.20, 794.88], ["AB", 31, 205.15, 205.15], ["NS", 14, 98.70, 276.36], ["MB", 10, 61.05, 146.52]];
const money = (n) => "$" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
console.log("Canadian orders since the new address form went live: " + rows.reduce((s, r) => s + r[1], 0) + "\n");
console.log("Province  Orders  Charged     Due         Short");
let short = 0;
for (const [p, n, charged, due] of rows) { short += due - charged; console.log(p.padEnd(10) + String(n).padEnd(8) + money(charged).padEnd(12) + money(due).padEnd(12) + money(due - charged)); }
console.log("\nShort in all: " + money(short) + " on " + rows.filter((r) => r[3] > r[2]).reduce((s, r) => s + r[1], 0) + " orders (Alberta has no provincial tax, so its orders were right).");
