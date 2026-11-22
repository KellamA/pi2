import type { Order } from "../checkout/order.ts";
import { STATE_RATES } from "./us-rates.ts";

export function usRate(order: Order): number {
	return STATE_RATES[order.shipping.region ?? ""] ?? 0;
}
