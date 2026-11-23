// App Attest's verifier is the engine's own file (#672, P37), imported by its path and bundled into the Worker, so that
// the Mac and the relay check a phone with the very same code and there is no copy to fall out of step (docs/iphone.md
// 12.1; README.md, "The verifier"). test/verifier.test.ts checks that this is that file. If the file ever needs a change
// to run in a Worker, the change is made to it, in a pull request of its own, never in a copy here.

export { AppAttestError, verifyAttestation } from "../../engine/src/appattest.ts";
export type { AppAttestEnvironment, AppAttestExpected, AppAttestResult } from "../../engine/src/appattest.ts";
