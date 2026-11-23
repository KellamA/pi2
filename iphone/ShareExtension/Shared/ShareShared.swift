// Built into both the share extension and the app (docs/iphone-app.md, "The extensions"): what the two must agree on
// goes in this folder, such as how what was shared is handed to the app (#702). Only what both can build: Foundation,
// the system's frameworks and the package products both link, nothing from the app's other folders or the extension's.
// This file only keeps the folder; delete it once the folder holds another.
