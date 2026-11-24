// Vite's `import.meta.glob`, as sealed.test.ts uses it: every file a pattern matches, each as its text, so that the
// check that the relay writes nothing to the console covers a file added to relay/src later without naming it.
interface ImportMeta {
	glob<T>(pattern: string, options: { query: "?raw"; import: "default"; eager: true }): Record<string, T>;
}
