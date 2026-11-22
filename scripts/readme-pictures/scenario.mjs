// What each staged conversation says and does. A turn is chosen by the newest message from the person (or a wake);
// its steps are the answers in order, each with text and tool calls ([name, arguments]). `delay` is in milliseconds.
const plan = (...items) => ["update_plan", { items: items.map(([content, status]) => ({ content, status })) }];
const work = (args) => ["work", args];
const woke = (said, key) => said.startsWith("[pi² woke you") && said.includes(key);

export const turns = [
	// ---- storefront: the orchestrator
	{
		name: "storefront orchestrator",
		match: (said) => said.includes("charged the wrong tax"),
		steps: [
			{
				text: "Two separate fixes, so I'll split them: the tax bug to Forge and the logo to Quill. Atlas can run the checkout end-to-end suite meanwhile, so we know the rest of checkout holds before anything ships, and Scout can work out how many orders were affected. Filing the work first.",
				tools: [work({ action: "file", title: "Wrong sales tax on Canadian orders", text: "Orders shipped to Canada since the new address form went live were charged 5% GST only, whatever the province. Find the cause, fix it, and add a test for every province." })],
			},
			{ text: "", tools: [work({ action: "file", title: "Old logo in the order confirmation email", text: "The order confirmation email still shows the 2019 logo. Swap it for the current one, and check the other emails." })] },
			{ text: "", tools: [work({ action: "file", title: "Run the checkout end-to-end suite", text: "Run the full checkout suite on main and report anything that fails." })] },
			{
				text: "",
				tools: [
					work({ action: "assign", id: 1, agent: "Forge", worktree: "fix/canada-tax", task: "Push a branch for review when the tests pass; don't merge." }),
					work({ action: "assign", id: 2, agent: "Quill", worktree: false }),
					work({ action: "assign", id: 3, agent: "Atlas", worktree: false }),
					["delegate", { agent: "Scout", title: "Count the under-taxed orders", wait: false, task: "Since the new address form went live, Canadian orders were charged 5% GST whatever the province. Work out how many orders were short, and by how much in each province. `node scripts/tax-shortfall.mjs` in the storefront repository reads the order export." }],
				],
			},
			{
				text: "All four are under way:\n\n- **#1** Wrong sales tax on Canadian orders: Forge\n- **#2** Old logo in the order confirmation email: Quill\n- **#3** Checkout end-to-end suite: Atlas\n- How many orders were short, and by how much: Scout\n\nI'll read their reports as they come in. Nothing ships until you say so.",
			},
		],
	},
	{
		name: "storefront wake: Scout",
		match: (said) => woke(said, "Count the under-taxed orders"),
		steps: [
			{
				text: "Scout has the numbers: **281 orders** were short **$3,179.49** in tax, most of it in Ontario ($1,629.44) and Quebec ($823.24). Alberta's 31 orders were right, since it has no provincial tax.\n\nWhether to collect that from customers is yours to decide, so I've put it under Needs you.",
				tools: [["needs_you", { action: "ask", question: "281 Canadian orders were short $3,179.49 in sales tax. Shall we absorb it, or ask finance first whether to collect it from customers?", choices: ["Absorb it", "Ask finance first"] }]],
			},
			{ text: "Forge has a fix, with a test for every province, and is waiting for you to allow the push. Atlas is still running the end-to-end suite." },
		],
	},
	{
		name: "storefront wake: Quill",
		match: (said) => woke(said, "Old logo in the order confirmation email"),
		steps: [
			{
				text: "Quill has finished #2: the order confirmation email now shows the current logo, with a PNG fallback for Outlook. The shipping and refund emails already had it. Quill noticed that the PDF invoices still carry the 2019 logo, but they are made by the billing service, outside this repository, so I've left a note on the work item rather than filing anything.",
				tools: [work({ action: "note", id: 2, text: "The PDF invoices still carry the 2019 logo; they are made by the billing service." })],
			},
			{ text: "Forge and Atlas are still at work, and Scout is counting the orders that were short." },
		],
	},
	{
		name: "storefront wake: Atlas",
		match: (said) => woke(said, "Run the checkout end-to-end suite"),
		steps: [{ text: "Atlas reports all 38 checkout scenarios pass on main." }],
	},
	// ---- storefront: Forge, on the tax bug
	{
		name: "Forge: tax",
		match: (said) => said.startsWith("Work #") && said.includes("Wrong sales tax on Canadian orders"),
		steps: [
			{
				text: "Starting where the tax rate is chosen.",
				tools: [
					plan(["Find where the province is read", "in_progress"], ["Fix the lookup", "pending"], ["Add a test for each province", "pending"], ["Push a branch for review", "pending"]),
					["search_files", { query: "rateFor", path: "src" }],
				],
			},
			{ text: "", tools: [["read", { path: "src/tax/rates.ts" }], ["read", { path: "src/checkout/address.ts" }]] },
			{
				text: "Found it. `rateFor()` looks the province up in `shipping.region`, but since the new address form, Canadian addresses keep it in `shipping.province`. The lookup finds nothing and falls back to the 5% federal GST, so an Ontario order paid 5% instead of 13% HST, a Quebec one 5% instead of 14.975%, and so on.",
				tools: [
					plan(["Find where the province is read", "completed"], ["Fix the lookup", "in_progress"], ["Add a test for each province", "pending"], ["Push a branch for review", "pending"]),
					["edit", { path: "src/tax/rates.ts", edits: [{ oldText: "\treturn PROVINCIAL[order.shipping.region] ?? FEDERAL_GST;", newText: "\tconst province = order.shipping.province ?? order.shipping.region ?? \"\";\n\treturn PROVINCIAL[province] ?? FEDERAL_GST;" }] }],
				],
			},
			{
				text: "Now a test for every province, so a change to the address's shape can't do this quietly again.",
				tools: [
					plan(["Find where the province is read", "completed"], ["Fix the lookup", "completed"], ["Add a test for each province", "in_progress"], ["Push a branch for review", "pending"]),
					["write", { path: "tests/tax.canada.test.ts", content: "import { test } from \"node:test\";\nimport assert from \"node:assert/strict\";\nimport { rateFor } from \"../src/tax/rates.ts\";\n\nconst RATES = { AB: 0.05, BC: 0.12, MB: 0.12, NB: 0.15, NL: 0.15, NS: 0.14, NT: 0.05, NU: 0.05, ON: 0.13, PE: 0.15, QC: 0.14975, SK: 0.11, YT: 0.05 };\nconst order = (province: string) => ({ id: \"1\", lines: [], shipping: { name: \"\", line1: \"\", city: \"\", country: \"CA\", province, postcode: \"\" } });\n\nfor (const [province, rate] of Object.entries(RATES)) {\n\ttest(`${province} ${+(rate * 100).toFixed(3)}%`, () => assert.equal(rateFor(order(province)), rate));\n}\n" }],
				],
			},
			{ text: "", tools: [["bash", { command: "npm test" }]] },
			{
				text: "All 214 tests pass, the 13 new ones with them. Committing.",
				tools: [["bash", { command: "git add -A && git commit -qm \"Tax Canadian orders by province again\" && git log --oneline -1" }]],
			},
			{
				text: "",
				tools: [
					plan(["Find where the province is read", "completed"], ["Fix the lookup", "completed"], ["Add a test for each province", "completed"], ["Push a branch for review", "in_progress"]),
					["bash", { command: "git push -u origin fix/canada-tax" }],
				],
			},
			{ text: "The branch is pushed: fix/canada-tax, one commit, ready for review." },
		],
	},
	// ---- storefront: Quill, on the logo
	{
		name: "Quill: logo",
		match: (said) => said.startsWith("Work #") && said.includes("Old logo in the order confirmation email"),
		steps: [
			{ delay: 3000, text: "Looking for the logo in the email templates.", tools: [["search_files", { query: "logo", path: "emails" }]] },
			{
				delay: 3000,
				text: "Only the order confirmation still points at the 2019 logo; the shipping and refund emails already use the current one.",
				tools: [["edit", { path: "emails/order-confirmation.html", edits: [{ oldText: "<img src=\"https://cdn.example.com/brand/logo-2019.png\" alt=\"Northwind\" width=\"140\">", newText: "<!--[if mso]><img src=\"https://cdn.example.com/brand/logo@2x.png\" alt=\"Northwind\" width=\"140\"><![endif]-->\n      <!--[if !mso]><!--><img src=\"https://cdn.example.com/brand/logo.svg\" alt=\"Northwind\" width=\"140\"><!--<![endif]-->" }] }]],
			},
			{ delay: 2000, text: "", tools: [work({ action: "finish", id: 2, text: "The order confirmation email shows the current logo, with a PNG fallback for Outlook." })] },
			{
				text: "Done. The order confirmation email now shows the current logo (`brand/logo.svg`), with `brand/logo@2x.png` for Outlook, which does not show SVG. The shipping and refund emails already had it.\n\nOne thing outside this repository: the PDF invoices still carry the 2019 logo. They are made by the billing service.",
			},
		],
	},
	// ---- storefront: Atlas, the end-to-end suite
	{
		name: "Atlas: e2e",
		match: (said) => said.startsWith("Work #") && said.includes("Run the checkout end-to-end suite"),
		steps: [
			{ text: "Running the checkout suite on main.", tools: [["bash", { command: "npm run test:e2e", timeout: 600 }]] },
			{ text: "All 38 checkout scenarios pass on main: cards, PayPal, Apple Pay, gift cards, discounts, and US, EU, UK and Canadian tax. The Canadian scenarios still set the old `region` field, which is why they passed; they should set `province` once Forge's fix is in." },
		],
	},
	// ---- storefront: Scout, counting the orders
	{
		name: "Scout: shortfall",
		match: (said) => said.includes("Work out how many orders were short"),
		steps: [
			{ delay: 30000, text: "Running the shortfall report on the order export.", tools: [["bash", { command: "node scripts/tax-shortfall.mjs" }]] },
			{ delay: 6000, text: "281 orders were short **$3,179.49** in tax in all:\n\n| Province | Orders | Short |\n|---|---:|---:|\n| Ontario | 141 | $1,629.44 |\n| Quebec | 64 | $823.24 |\n| British Columbia | 52 | $463.68 |\n| Nova Scotia | 14 | $177.66 |\n| Manitoba | 10 | $85.47 |\n\nAlberta's 31 orders were charged correctly, since it has no provincial sales tax." },
		],
	},

	// ---- docs-site
	{
		name: "docs orchestrator",
		match: (said) => said.includes("still documents the v1 endpoints"),
		steps: [
			{
				text: "Wren can do the rewrite. One question for you before it touches the v1 pages.",
				tools: [
					work({ action: "file", title: "API reference for v2", text: "Rewrite the API reference for v2 before Thursday's launch: every endpoint whose request or response changed, and the new ones." }),
					["needs_you", { action: "ask", question: "Once the v2 reference is up, should the v1 pages stay with a notice that v1 is deprecated, or redirect to their v2 pages?", choices: ["Keep v1 with a notice", "Redirect to v2"] }],
				],
			},
			{ text: "", tools: [work({ action: "assign", id: 1, agent: "Wren", worktree: false, task: "Start with the endpoints whose shape changed. Leave the v1 pages alone until the person has decided what happens to them." })] },
			{ text: "Wren is on it (#1), starting with the endpoints whose request or response changed. Your answer on the v1 pages is under Needs you; Wren leaves them alone until then." },
		],
	},
	{
		name: "Wren: docs",
		match: (said) => said.startsWith("Work #") && said.includes("API reference for v2"),
		steps: [{ text: "Comparing the v1 and v2 schemas first, to see which pages change.", tools: [["bash", { command: "npm run docs:diff -- v1 v2", timeout: 600 }]] }],
	},

	// ---- mobile-app
	{
		name: "mobile orchestrator",
		match: (said) => said.startsWith("Last night's TestFlight build failed"),
		steps: [
			{ text: "Handing the build log to Sage.", tools: [["delegate", { agent: "Sage", title: "Why the nightly build failed", task: "The nightly TestFlight build failed. Read build/logs/nightly.log in the mobile-app repository and say what failed and why, in a few lines." }]] },
			{ text: "It didn't fail to compile: it failed at signing. The **Apple Distribution certificate expired on 16 November**, so the archive could not be signed.\n\nRenewing it needs your Apple developer account, so that one is yours: in Xcode, **Settings › Accounts › Manage Certificates…**, then **+ › Apple Distribution**. Tell me once it's done and I'll start the build again." },
		],
	},
	{
		name: "Sage: build log",
		match: (said) => said.includes("Read build/logs/nightly.log"),
		steps: [
			{ text: "", tools: [["read", { path: "build/logs/nightly.log" }]] },
			{ text: "The build compiled and linked; it failed at code signing. `No signing certificate \"Apple Distribution\" found`: the distribution certificate for the team expired on 16 Nov at 09:12, so the archive was never signed or uploaded. Renewing the certificate (and the provisioning profile, if it was tied to the old one) fixes it." },
		],
	},

	// ---- chat mode
	{
		name: "chat: tax",
		match: (said) => said.includes("GST, HST and PST"),
		steps: [
			{
				text: "Canada has three kinds of sales tax, and which ones apply depends on the province the goods go to:\n\n- **GST** (Goods and Services Tax) is federal: 5% everywhere in Canada.\n- **PST** (Provincial Sales Tax) is a separate provincial tax, charged on top of GST in British Columbia, Saskatchewan, Manitoba and Quebec (where it is called QST).\n- **HST** (Harmonized Sales Tax) replaces both in the Atlantic provinces and Ontario: one combined rate, collected as one tax.\n\n| Province | What applies | Total |\n|---|---|---:|\n| Alberta, the territories | GST | 5% |\n| British Columbia | GST + PST 7% | 12% |\n| Quebec | GST + QST 9.975% | 14.975% |\n| Ontario | HST | 13% |\n| Nova Scotia | HST | 14% |\n| New Brunswick, Newfoundland, PEI | HST | 15% |\n\nFor an online shop, the rate follows the **shipping address**, not where the shop is. If you sell into a PST province you may also need to register there separately, while GST/HST is registered once with the CRA.",
			},
		],
	},
];
