/*
 * What a chat adds to the conversation page (#285): under an answer, Try Again (with the choice of another model) and
 * the sources it read; on the person's own message, Edit; and where a message or an answer has several versions, the
 * control that steps between them.
 *
 * Pure functions over what the app sends and the page's items, so Node can test them. Loaded as a plain script by the
 * page (it sets `PiChat`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiChat = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
	const str = (value) => (typeof value === "string" ? value : "");
	const MIDDOT = String.fromCharCode(0xb7);

	/** Nothing of a chat's own: an agent's conversation, until the app says otherwise. */
	const NONE = Object.freeze({ enabled: false, versions: [], models: [], model: "" });

	/**
	 * The app's `chat` message, checked: whether this is a chat, where its versions part (`after` an entry, or null
	 * before the first message; `index` of `count`), the models Try Again may use (as the model selector lists them),
	 * and the model in use as "provider/id".
	 */
	function read(message) {
		if (!isObject(message) || message.enabled !== true) return NONE;
		const whole = (value) => Number.isInteger(value) && value >= 0;
		const versions = (Array.isArray(message.versions) ? message.versions : []).filter(
			(point) => isObject(point) && (point.after === null || whole(point.after)) && whole(point.index) && whole(point.count) && point.count > 1 && point.index < point.count,
		);
		const models = (Array.isArray(message.models) ? message.models : [])
			.filter((model) => isObject(model) && str(model.provider) !== "" && str(model.id) !== "")
			.map((model) => ({ provider: model.provider, id: model.id, name: str(model.name) || model.id, group: str(model.group) || model.provider }));
		return { enabled: true, versions, models, model: str(message.model) };
	}

	/**
	 * Which row each point's control goes under: the first message or answer after the point. An answer's control goes
	 * with the turn's actions, under its last answer. Returns a Map from the row's item id to its point.
	 *
	 * `from` is the id of the first entry the page has while older ones are still to come (#440), or null: a point before
	 * it has its row among those, so it waits for them rather than land under the first row the page has.
	 */
	function versionRows(visible, versions, from = null) {
		const rows = new Map();
		for (const point of versions) {
			if (from !== null && (point.after === null || point.after < from)) continue;
			let index = visible.findIndex((item) => point.after === null || item.id > point.after);
			while (index !== -1 && index < visible.length && visible[index].kind !== "user" && visible[index].kind !== "assistant") index++;
			if (index === -1 || index >= visible.length) continue;
			if (visible[index].kind === "assistant") while (index + 1 < visible.length && visible[index + 1].kind === "assistant") index++;
			if (!rows.has(visible[index].id)) rows.set(visible[index].id, point);
		}
		return rows;
	}

	/** A web address's host as a person reads it, without "www.". */
	function host(url) {
		try {
			return new URL(url).host.replace(/^www\./, "");
		} catch {
			return "";
		}
	}

	/**
	 * The pages a turn read, from web_fetch's own results: each once, in the order read, with its title (or its host
	 * when it has none). A page a search only listed is not a source: the model saw a line about it, not the page.
	 * `safeURL` keeps only addresses the page may link to.
	 */
	function sources(turn, results, safeURL) {
		const found = [];
		const seen = new Set();
		for (const item of turn) {
			for (const call of Array.isArray(item.toolCalls) ? item.toolCalls : []) {
				if (!isObject(call) || call.name !== "web_fetch") continue;
				const result = results.get(call.callId);
				if (!result || result.isError) continue;
				const source = isObject(result.details) && isObject(result.details.source) ? result.details.source : null;
				const url = source ? safeURL(str(source.url)) : null;
				if (!url || seen.has(url)) continue;
				seen.add(url);
				const site = host(url);
				found.push({ url, title: str(source.title).trim() || site || url, host: site });
			}
		}
		return found;
	}

	/** A source's link text: its title, and its site when the title does not already say it. */
	function sourceLabel(source) {
		return source.host && source.title !== source.host ? `${source.title} ${MIDDOT} ${source.host}` : source.title;
	}

	/** The models Try Again offers, by provider in the order given, as the model selector groups them. */
	function modelGroups(models) {
		const groups = [];
		for (const model of models) {
			let group = groups.find((each) => each.name === model.group);
			if (!group) groups.push((group = { name: model.group, models: [] }));
			group.models.push(model);
		}
		return groups;
	}

	return { NONE, read, versionRows, sources, sourceLabel, modelGroups, host };
});
