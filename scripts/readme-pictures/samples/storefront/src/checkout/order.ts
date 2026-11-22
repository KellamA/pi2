import type { Address } from "./address.ts";

export type Line = { sku: string; quantity: number; price: number };
export type Order = { id: string; lines: Line[]; shipping: Address; discount?: number };
