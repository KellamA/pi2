// Built into both the app and the notification service extension (docs/iphone-app.md, "The extensions"), and #690's
// (P21): what the two must agree on goes in this folder, such as opening `sealed` with the record key, and the
// extension's own small file, which it writes and the app merges into its store (docs/iphone.md 3.6, section 7). Only
// what both can build: Foundation, the system's frameworks and the package products both link, nothing from the app's
// other folders. This file only keeps the folder; delete it once the folder holds another.
