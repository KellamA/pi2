import type { Order } from "../checkout/order.ts";
import { usRate } from "./us.ts";

/** Federal GST, charged on every Canadian order. */
export const FEDERAL_GST = 0.05;

/** Combined federal and provincial sales tax, by province. */
const PROVINCIAL: Record<string, number> = {
	AB: 0.05, BC: 0.12, MB: 0.12, NB: 0.15, NL: 0.15, NS: 0.14, NT: 0.05,
	NU: 0.05, ON: 0.13, PE: 0.15, QC: 0.14975, SK: 0.11, YT: 0.05,
};

/** The sales tax rate for an order, from where it ships. */
export function rateFor(order: Order): number {
	if (order.shipping.country !== "CA") return usRate(order);
	return PROVINCIAL[order.shipping.region] ?? FEDERAL_GST;
}
