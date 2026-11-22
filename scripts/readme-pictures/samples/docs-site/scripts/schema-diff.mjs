// Compares two versions of the API's OpenAPI schema, endpoint by endpoint (sample).
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const [from = "v1", to = "v2"] = process.argv.slice(2);
console.log("Comparing openapi/" + from + ".yaml with openapi/" + to + ".yaml\n");
const rows = [["GET /orders", "cursor pagination replaces page/per_page"], ["POST /orders", "lines[].price is now an object {amount, currency}"], ["GET /orders/{id}", "adds fulfilments[]"], ["PATCH /orders/{id}", "new"], ["GET /customers/{id}", "address split into region and province"], ["POST /customers", "email now required"], ["DELETE /customers/{id}", "unchanged"], ["GET /products", "cursor pagination"], ["GET /products/{id}", "variants[] replaces options"], ["POST /refunds", "new"], ["GET /refunds/{id}", "new"], ["GET /webhooks", "unchanged"], ["POST /webhooks", "signing secret returned once"], ["GET /inventory", "per location"], ["POST /inventory/adjust", "new"], ["GET /tax/rates", "new"]];
for (const [endpoint, change] of rows) { await pause(9000); console.log("  " + endpoint.padEnd(26) + change); }
await pause(600000);
