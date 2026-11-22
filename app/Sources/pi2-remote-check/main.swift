// Checks RemoteKit (#674): Noise against the published test vectors for the two protocols pi² uses, HPKE against
// RFC 9180's for the suite it uses, a pairing and a KK connection between two ends of its own in memory, sealed items
// both ways, and what each reader refuses. It makes every key in software and touches no key store, no file but its
// fixtures, and no network.
//
//   cd app && swift build --product pi2-remote-check && .build/debug/pi2-remote-check
//
// `--vectors <folder>` reads the fixtures from another folder than the one beside this file.

import Foundation

Vectors.noise()
Vectors.hpke()
Formats.run()
Sessions.run()
Sessions.secureEnclaveRecordKeyCompiles()
Sessions.errorsHoldNoSecret()
print("\(Check.passed) passed, \(Check.failed.count) failed")
exit(Check.failed.isEmpty ? 0 : 1)
