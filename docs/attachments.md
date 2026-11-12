# Attachments

A message can carry pictures and files as well as what you type. It can also be attachments alone.

## Ways in

- **Paste.** With the cursor in the message field, ⌘V attaches a copied picture (a screenshot, an image copied in a browser or Preview) or files copied in Finder. Ordinary text pastes as text. A very long paste, more than about 4,000 characters or 60 lines, becomes a "Pasted text" attachment instead of filling the field.
- **Drop.** Drag files or pictures onto the conversation.
- **The paperclip** in the message field opens a file picker.

Each attachment shows as a chip above the message field, with a button to remove it. If something cannot be used, its chip says why, and the message goes without it. Attachments can be sent while the agent is working, to steer it or to queue behind it, like any message.

## What can be attached

| Kind | What the model gets |
|---|---|
| Pictures: PNG, JPEG, GIF, WebP, HEIC, TIFF, and anything else macOS can open | The picture, scaled so its longer side is at most 2,000 pixels. Sent as PNG when part of it is see-through or it is small, as JPEG otherwise. Only the first frame of an animation. |
| Text and code files, in UTF-8, UTF-16 or an older one-byte encoding | The text. SVG files are sent as their text. |
| PDF | Its text, with page numbers. A PDF with no text in it, such as a scan, is sent as pictures of its first five pages. |
| Word (.docx, .doc), RTF, RTFD, OpenDocument text (.odt), web pages (.html) | The plain text. |
| A long paste | The text. |

Not yet: spreadsheets, presentations, Pages documents, archives, audio, video, folders, and PDFs protected with a password. A spreadsheet can be exported as CSV, and most other documents as PDF.

Pictures are drawn afresh before they are sent, so what a photo's file says about where and with what it was taken stays on your Mac. Everything else in an attachment goes to the conversation's model provider, as the message does.

## Limits

- At most 10 attachments in a message.
- A picture at most 5 MB once prepared. The app scales and compresses to stay under that.
- An attached text at most 400,000 characters, and 1,500,000 across one message.

Attached text counts towards the model's context like anything else in the conversation. A long PDF can fill a small model's context on its own.

## Models that cannot see pictures

If the conversation's model does not take pictures, picture chips are marked, a line under them says so, and the message cannot be sent until you choose another model or remove them. Files are not affected.

A model on your own endpoint (Ollama, LM Studio and the like) is treated as text-only until you say otherwise: pi² cannot ask the server. In **Settings › Providers**, add or edit the endpoint and switch the model on under **Can see pictures**. That also lets it get screenshots in [computer use](computer-use.md).

## In the transcript

A sent message shows its pictures as thumbnails (click one to enlarge it) and its files as chips with their names and sizes. The typed text is shown on its own; the contents of the files are not repeated. An export names a message's attachments.

## How it is stored

The engine takes attachments with `submit` as `{ kind: "image", name, mimeType, data }` (base64) or `{ kind: "text", name, text }`. The model's message is the typed text, then one text block for each attached text under a line `Attached file: <name>`, then the pictures. Beside it, the entry (kind `pi2.user`) records what the transcript shows: the typed text, and each attachment's name, kind and size. Pictures are not sent with the transcript; the app fetches one with `conversation.image` when it shows it.
