// Presenting (#946, docs/design/presenting.md): the requests it adds, named in answers.ts's lists before anything
// answers them (#963), so that the owner's path changes once, small, and first. Until the engine's part is built, one
// stub answers all six, and nothing is stored, read or drawn: who may send each is answers.ts's alone, as for any request.

import type { Feature } from "./features.ts";

/** What every one of presenting's requests answers until the engine's part is built. */
export const PRESENTING_NOT_YET = "Presenting is not available yet.";

const notYet = async (): Promise<never> => {
	throw new Error(PRESENTING_NOT_YET);
};

export const presented: Feature = () => ({
	// Piece 2 of #946's roadmap replaces this stub with each request's handler, here; the names stay as they are.
	handlers: {
		"present.register": notYet,
		"present.drawn": notYet,
		"presented.list": notYet,
		"presented.picture": notYet,
		"presented.file": notYet,
		"presented.network": notYet,
	},
});
