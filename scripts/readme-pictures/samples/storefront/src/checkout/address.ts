/** A shipping address, as the checkout form keeps it. */
export type Address = {
	name: string;
	line1: string;
	line2?: string;
	city: string;
	country: string;
	/** A US state, two letters. */
	region?: string;
	/** A Canadian province, two letters. Kept apart from `region` since the new address form. */
	province?: string;
	postcode: string;
};
