// Built into both the widgets extension and the app (docs/iphone-app.md, "The extensions"): what the two must agree on
// goes in this folder, such as the widgets' file the app writes and the widgets read (#699), and the Live Activity's
// attributes, which the app starts and the extension draws (#700), each in a file of its own issue. Only what both can
// build: Foundation, the system's frameworks and the package products both link, nothing from the app's other folders
// or the extension's. This file only keeps the folder; delete it once the folder holds another.
