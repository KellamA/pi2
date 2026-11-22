// A file's text, as Vite gives it for an import ending in `?raw`.
declare module "*?raw" {
	const text: string;
	export default text;
}
