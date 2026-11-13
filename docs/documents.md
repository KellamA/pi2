# Formatted documents

One tool, `write_document`, turns Markdown into a document someone can send or print: a Word file, an RTF file, an OpenDocument file or an HTML page. Without it an agent can only write Markdown or plain text with the `write` tool.

The code is `engine/src/documents.ts`. The engine does all the work with what macOS ships (`/usr/bin/textutil`), so nothing is installed, the pi² app need not be open, and a scheduled run can write documents too.

## The tool

`write_document { path, markdown, title?, overwrite? }`

| Argument | Meaning |
| --- | --- |
| `path` | The file to write, relative to the conversation's folder or absolute inside it. The ending chooses the format. |
| `markdown` | The content. |
| `title` | Optional. Becomes the document's title property. If the Markdown does not open with a heading, it is also added at the top as one. |
| `overwrite` | A file that already exists is not replaced unless this is `true`. The refusal says so. |

| Ending | Format |
| --- | --- |
| `.docx` | Word |
| `.rtf` | Rich Text |
| `.odt` | OpenDocument text |
| `.html` | A standalone HTML page (styles inside it, no other files) |

Any other ending is refused with a message listing these. So is `.pdf`, with a message suggesting `.docx` (see "PDF" below). Missing folders in the path are created. Up to 2 million characters of Markdown.

The prompt tells the model to use it when the person asks for a document to send, print or open in a word processor, and not for notes, code or data.

## Access and approval

It writes a file, so it follows the built-in `write` tool:

- It is given to a conversation only when the access level allows writing (**Ask first** or **Full access**), never with **No tools** or **Read files**.
- Under **Ask first**, a call waits for the person like `write` and `edit` do (`write_document` is in the same list in `extensions.ts`), and the approval card reads "wants to write a Word document" (or an RTF document, OpenDocument file or HTML page) over the file name. **Always allow** covers the tool for the rest of that conversation.
- It writes only inside the conversation's folder (the scratch folder when none was chosen). A path that lands outside once every link is resolved is refused, and it never writes through a link: an existing link at the target is refused even with `overwrite`. This is stricter than `write`, which accepts any path the person's account can reach.
- A crash during a write is not repeated on restart; the agent is told, and can check the file.

## What it makes

The Markdown is converted to clean, styled HTML by a small converter in the engine (no packages), and that HTML is either the `.html` file or the input to `textutil -convert`. The converter understands:

- headings `#` to `######` and underlined headings
- paragraphs with line breaks
- **bold**, *italic*, ~~strikethrough~~, `inline code`
- fenced code blocks (and indented lists inside lists, quotes in lists, and so on, to a depth of 12)
- bullet and numbered lists, nested; a numbered list keeps its first number
- task lists (`- [ ]`, `- [x]`), shown as ☐ and ☑ in front of the item
- tables, with column alignment and `\|` for a pipe in a cell
- block quotes, horizontal rules
- links to `http`, `https` and `mailto` addresses, and bare addresses

The page uses Arial 11 pt for text, Courier New for code (fonts that Word has on Windows and Mac alike, rather than the Mac-only Helvetica Neue and Menlo), headings from 22 pt down, shaded code blocks, bordered tables with shaded header cells, and quotes indented in grey.

### Safe by construction

Text from a document is untrusted, so the converter never passes anything through:

- Every piece of text and every attribute value is escaped. Raw HTML in the Markdown (`<script>`, `<img onerror=…>`, comments, `<style>`) is shown as the text it is.
- Only `http`, `https` and `mailto` links are made. A link to anything else (`javascript:`, `data:`, `file:`, a relative path) keeps its words and loses its address.
- A quote in a link's title or address cannot end the attribute.
- Pictures are not fetched or embedded (textutil would otherwise fetch a remote picture or embed a local file); the description is kept in italics.
- The title is escaped, and a title that looks like an option is never passed to `textutil` as one.
- `textutil` is run by its fixed path, with the arguments as a list and no shell, with a 30 second limit, on files in a private temporary folder that is removed afterwards. The result is copied into place only if nothing is there (or `overwrite` is true), so a document is never left half written.

## What survives conversion

Checked by writing each format, then reading it back with `textutil` (as text and as HTML) in `engine/test/documents.ts`.

| | `.html` | `.rtf` | `.odt` | `.docx` |
| --- | --- | --- | --- | --- |
| Headings (size and bold) | yes | yes | yes | yes |
| Bold, italic, strikethrough | yes | yes | yes | yes |
| Inline code and code blocks in a monospace face | yes | yes | yes | yes |
| Code block shading | yes | yes | yes | no |
| Nested bullet and numbered lists | yes | yes | yes | yes |
| Tables with borders and shaded header | yes | yes | yes | no, see below |
| Links | yes | yes | yes | no, see below |
| Quote indent and colour | yes | yes | yes | yes |
| Title property | yes | yes | yes | yes |

What does not survive, anywhere:

- **Headings are formatting, not styles.** `textutil` writes a heading as large bold text. Word's navigation pane, a table of contents and "Heading 1" styles do not see them.
- **Lists are typed bullets with a hanging indent**, not Word's list objects. Numbers are fixed; adding an item in Word will not renumber. Task lists show a bullet as well as the box.
- **Quote bars and horizontal rules.** A quote is indented and grey, without the bar at its side; a rule is an empty line.
- **Pictures** are not included.
- **Page setup** is the program's default (page size, margins). There are no headers, footers or page numbers.

What does not survive in `.docx` in particular: the Word writer in macOS's `textutil` keeps no tables, no hyperlinks and no paragraph or code shading. Rather than lose them silently, the converter changes the content for `.docx` only:

- **A table becomes an aligned text grid** in the monospace face, with a line of dashes under the header. It reads well and prints well, but it is text, not a Word table. If the person needs a real table, `.rtf` or `.odt` have it (Word, Pages and LibreOffice open both).
- **A link is written as its words followed by the address in brackets**, "the report (https://example.com)", so a printed copy keeps the address.

The tool's answer tells the model when it did this, so it can say so to the person.

## PDF

Not offered. macOS has no command-line HTML-to-PDF converter that is dependable from a background process: `textutil` cannot write PDF, `cupsfilter` has only a plain-text filter (no styling), and the converters that render HTML (WebKit, Quick Look, the print system through AppKit) need a running app with a window server. Bridging to the pi² app for it was ruled out. A `.pdf` ending is refused with a message suggesting `.docx`, which the person can save as a PDF from Word or Pages.

## Tests

`engine/test/documents.ts` (run by `npm test`, or alone with `npm run test:documents`) covers every construct, hostile input (script tags, `javascript:` links, attribute injection through titles and addresses, deeply nested and very long input) with a check that the output contains only the tags and attributes the converter writes, and a real round trip through `textutil` for each format in a temporary folder. `engine/test/engine.ts` checks the tool end to end: absent without write access, approval under **Ask first** (deny writes nothing, **Always allow** stops the questions), a `.docx` that is a real Word file, and the refusals.
