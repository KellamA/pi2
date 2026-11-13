// Archiving and deleting conversations.
//
// An archived conversation leaves the sidebar and is kept in the Archive, where it can be read, found by search and
// brought back. A deleted one is shown nowhere again. Neither erases anything: pi durable has no way to remove a
// conversation's entries from the session file, so "deleted" means pi² stops showing it, not that the bytes are gone.

import type { Meta } from "./state.ts";

const DAY = 86_400_000;
/** The longest a conversation may be left before it is archived on its own: ten years, far past any real use. */
export const MAX_AUTO_ARCHIVE_DAYS = 3650;

export const isDeleted = (meta: Meta | undefined): boolean => meta?.deleted === true;
export const isArchived = (meta: Meta | undefined): boolean => meta !== undefined && meta.deleted !== true && meta.archivedAt !== undefined;
/** Out of the sidebar, for either reason. */
export const isPutAway = (meta: Meta | undefined): boolean => meta !== undefined && (meta.deleted === true || meta.archivedAt !== undefined);

/**
 * Before there was an archive, deleting a conversation set `archived`. Those were deleted as far as the person is
 * concerned, so they must not turn up in the Archive now: each becomes `deleted`. Returns whether anything changed.
 */
export function migrateDeleted(conversations: Record<string, Meta>): boolean {
	let changed = false;
	for (const meta of Object.values(conversations)) {
		if (meta.archived === undefined) continue;
		if (meta.archived === true && meta.archivedAt === undefined) meta.deleted = true;
		delete meta.archived;
		changed = true;
	}
	return changed;
}

/** `days` as the setting accepts it: a whole number of days from 1 up, or null for never. */
export function validateAutoArchive(days: unknown): number | null {
	if (days === null || days === undefined) return null;
	if (typeof days !== "number" || !Number.isInteger(days) || days < 1 || days > MAX_AUTO_ARCHIVE_DAYS) {
		throw new Error(`Choose a whole number of days from 1 to ${MAX_AUTO_ARCHIVE_DAYS}, or never`);
	}
	return days;
}

/**
 * The conversations to archive because nothing has happened in them for `days` days: top-level ones only (a sub-chat
 * goes with its parent), not already put away, and with nothing going on in them or their sub-chats: `active` says
 * whether a conversation is working or waiting on the person.
 */
export function dueForArchive(conversations: Record<string, Meta>, now: number, days: number | null, active: (id: number) => boolean): number[] {
	if (days === null) return [];
	const cutoff = now - days * DAY;
	const due: number[] = [];
	for (const [key, meta] of Object.entries(conversations)) {
		const id = Number(key);
		if (meta.parent !== undefined || isPutAway(meta)) continue;
		const children = Object.entries(conversations).filter(([, child]) => child.parent === id && !isDeleted(child));
		// A sub-chat used more recently than its parent keeps the whole conversation.
		const lastUsed = Math.max(meta.updatedAt, ...children.map(([, child]) => child.updatedAt));
		if (lastUsed > cutoff) continue;
		if (active(id) || children.some(([child]) => active(Number(child)))) continue;
		due.push(id);
	}
	return due;
}
