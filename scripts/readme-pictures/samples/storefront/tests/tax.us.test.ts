import { test } from "node:test";
import assert from "node:assert/strict";
import { rateFor } from "../src/tax/rates.ts";

test("US orders use the state rate", () => {
	assert.equal(rateFor({ id: "1", lines: [], shipping: { name: "", line1: "", city: "Austin", country: "US", region: "TX", postcode: "78701" } }), 0.0625);
});
