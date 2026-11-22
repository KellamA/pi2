// Which pairing and device each App Attest key the relay checked is tied to (README.md, "join"). Apple's guidance is to
// make sure an attested key is not already in use before trusting it; a pairing's own object cannot see other
// pairings, so each key has an object of its own, named by its id: one key, one place, any number of pairings
// (docs/iphone.md 9.2).
//
// A tie lasts a week, then goes by itself. It is needed only while the key's attestation could still be checked: its
// leaf certificate is valid until about two days after the attestation was made, and the verifier refuses it after
// that, while App Attest attests a key once only (`DCError.invalidKey`), so no new attestation of the same key can come.
// The expiry also means a tie that a failed call left behind does not stay for ever.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./settings.ts";

/** How long a tie lasts: longer than an attestation can be checked (two days after it is made, and a day of clock). */
export const TIE_FOR = 7 * 24 * 60 * 60 * 1000;

type Tie = { pairing: string; device: string; until: number };

export class AttestKey extends DurableObject<Env> {
	/** Ties the key to this pairing's device. False if it is tied to any other pairing or device. */
	async tie(pairing: string, device: string): Promise<boolean> {
		const tie = await this.current();
		if (tie !== null) return tie.pairing === pairing && tie.device === device;
		await this.put({ pairing, device, until: Date.now() + TIE_FOR });
		return true;
	}

	/**
	 * Moves the key from a phone's slot to the device the Mac added for it under another id, in the same pairing. False
	 * if it is tied to anything else. A tie that is gone (expired) is made anew for the device.
	 */
	async retie(pairing: string, from: string, to: string): Promise<boolean> {
		const tie = await this.current();
		if (tie !== null && (tie.pairing !== pairing || (tie.device !== from && tie.device !== to))) return false;
		await this.put({ pairing, device: to, until: tie?.until ?? Date.now() + TIE_FOR });
		return true;
	}

	/** Unties the key, if it is tied to this pairing's device: the device was removed or left, or the pairing deleted. */
	async untie(pairing: string, device: string): Promise<void> {
		const tie = await this.current();
		if (tie !== null && tie.pairing === pairing && tie.device === device) await this.forget();
	}

	async alarm(): Promise<void> {
		if ((await this.current()) === null) await this.forget();
	}

	private async current(): Promise<Tie | null> {
		const tie = await this.ctx.storage.get<Tie>("tie");
		return tie !== undefined && tie.until > Date.now() ? tie : null;
	}

	private async put(tie: Tie): Promise<void> {
		await this.ctx.storage.put("tie", tie);
		await this.ctx.storage.setAlarm(tie.until);
	}

	private async forget(): Promise<void> {
		await this.ctx.storage.deleteAlarm();
		await this.ctx.storage.deleteAll();
	}
}
