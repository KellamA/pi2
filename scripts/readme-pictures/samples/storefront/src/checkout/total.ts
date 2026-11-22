import { rateFor } from "../tax/rates.ts";
import type { Order } from "./order.ts";

export function total(order: Order): { subtotal: number; tax: number; total: number } {
	const subtotal = order.lines.reduce((sum, line) => sum + line.price * line.quantity, 0) - (order.discount ?? 0);
	const tax = Math.round(subtotal * rateFor(order) * 100) / 100;
	return { subtotal, tax, total: subtotal + tax };
}
