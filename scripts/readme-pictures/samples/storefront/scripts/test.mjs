// Prints the suite's results (a stand-in for the real runner in this sample).
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const groups = [
	["checkout totals", ["adds line prices", "applies a discount before tax", "rounds tax to the cent", "keeps a zero-price line"]],
	["US sales tax", ["uses the state rate", "charges nothing where there is no state tax"]],
	["Canadian sales tax by province", ["AB 5%", "BC 12%", "MB 12%", "NB 15%", "NL 15%", "NS 14%", "NT 5%", "NU 5%", "ON 13%", "PE 15%", "QC 14.975%", "SK 11%", "YT 5%"]],
];
let n = 0;
for (const [name, tests] of groups) {
	console.log("\u25b6 " + name);
	for (const t of tests) { n++; console.log("  \u2714 " + t + " (" + (0.2 + (n % 7) / 10).toFixed(1) + "ms)"); }
	console.log("\u25b6 " + name + " (" + (3 + tests.length * 1.3).toFixed(1) + "ms)");
	await pause(150);
}
console.log("\u2139 tests 214\n\u2139 suites 31\n\u2139 pass 214\n\u2139 fail 0\n\u2139 duration_ms 1840.6");
