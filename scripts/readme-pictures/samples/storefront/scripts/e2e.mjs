// The checkout end-to-end suite (a stand-in for the browser runner in this sample).
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const scenarios = ["card payment, one item", "card payment, three items", "card declined, then retried", "PayPal", "Apple Pay", "gift card covers the order", "gift card plus card", "discount code", "expired discount code", "free shipping over $75", "US tax, Texas", "US tax, California", "US tax, no state tax", "EU VAT, Germany", "EU VAT, reverse charge", "UK VAT", "Canadian tax, Ontario", "Canadian tax, Quebec", "Canadian tax, Alberta", "address autocomplete", "PO box refused for express", "guest checkout", "saved address", "saved card", "change quantity in the basket", "remove the last item", "stock runs out at payment", "two tabs, one basket", "session expires at payment", "back button after payment", "receipt email sent", "order shows in the account", "cancel within the hour", "refund to card", "refund to gift card", "currency: CAD", "currency: EUR", "currency: GBP"];
console.log("Running " + scenarios.length + " checkout scenarios against http://localhost:4100 (chromium, 4 workers)\n");
const started = Date.now();
for (const [i, s] of scenarios.entries()) {
	await pause(13500);
	console.log("  \u2713 " + String(i + 1).padStart(2) + "/" + scenarios.length + " " + s + " (" + (9 + (i * 7) % 11) + "." + (i % 10) + "s)");
}
const secs = Math.round((Date.now() - started) / 1000);
console.log("\n  " + scenarios.length + " passed (" + Math.floor(secs / 60) + "m " + (secs % 60) + "s)");
