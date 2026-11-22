// Which pairing and device each App Attest key is tied to (README.md, "join"). Apple's guidance is to make sure an
// attested key is not already in use before trusting it; a pairing's own object cannot see other pairings, so each key
// has an object of its own, named by its id: one key, one place, any number of pairings (docs/iphone.md 9.2).

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./settings.ts";

type Tie = { pairing: string; device: string };

export class AttestKey extends DurableObject<Env> {
	/** Ties the key to this pairing's device. False if it is tied to any other pairing or device. */
	async tie(pairing: string, device: string): Promise<boolean> {
		const tie = await this.ctx.storage.get<Tie>("tie");
		if (tie !== undefined) return tie.pairing === pairing && tie.device === device;
		await this.ctx.storage.put("tie", { pairing, device });
		return true;
	}

	/**
	 * Moves the key from a phone's slot to the device the Mac added for it, in the same pairing (a phone that joined
	 * and was then added under another id). False if it is tied to anything else.
	 */
	async retie(pairing: string, from: string, to: string): Promise<boolean> {
		const tie = await this.ctx.storage.get<Tie>("tie");
		if (tie === undefined || tie.pairing !== pairing || (tie.device !== from && tie.device !== to)) return false;
		await this.ctx.storage.put("tie", { pairing, device: to });
		return true;
	}

	/** Unties the key, if it is tied to this pairing's device: the device was removed or left, or the pairing deleted. */
	async untie(pairing: string, device: string): Promise<void> {
		const tie = await this.ctx.storage.get<Tie>("tie");
		if (tie !== undefined && tie.pairing === pairing && tie.device === device) await this.ctx.storage.deleteAll();
	}
}
