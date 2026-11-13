/// The JavaScript that reads a page and acts on it.
///
/// It runs in a content world of pi²'s own, so the page's scripts can neither see nor change it, and it is sent whole
/// with every call, so nothing depends on a script having been injected when the page loaded. The one thing it keeps
/// between calls is the list of elements from the newest view, which is what the numbers the agent uses refer to.
/// That list lives in the page's document: a new document starts without one, so a number from an earlier page is
/// never mistaken for something on this one.
enum PageScript {
    static let source = #"""
const S = globalThis.__pi2 || (globalThis.__pi2 = { records: null });

// Control characters go, among them the ones that reorder text on screen: a label is shown to the person for approval.
const squash = (s) => String(s == null ? '' : s).replace(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f‪-‮⁦-⁩]/g, '').replace(/\s+/g, ' ').trim();
// A page's words are always set between “ and ”, so they may not hold those marks themselves.
const clip = (s, n) => { s = squash(s).replace(/[“”]/g, '"'); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const quote = (s) => '“' + s + '”';
const tagOf = (el) => String(el.tagName || '').toUpperCase();
const styleOf = (el) => (el.ownerDocument.defaultView || window).getComputedStyle(el);

const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'TITLE', 'SVG', 'CANVAS', 'VIDEO', 'AUDIO', 'OBJECT', 'EMBED', 'MAP', 'DATALIST', 'PARAM', 'SOURCE', 'TRACK']);
const APART = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'DL', 'TABLE', 'BLOCKQUOTE', 'PRE', 'SECTION', 'ARTICLE', 'FORM', 'FIELDSET', 'HEADER', 'FOOTER', 'NAV', 'ASIDE', 'MAIN', 'FIGURE', 'DETAILS', 'DIALOG']);
const FIELD_NAMES = { email: 'email field', password: 'password field', search: 'search field', tel: 'phone field', url: 'address field', number: 'number field', date: 'date field', time: 'time field', 'datetime-local': 'date and time field', month: 'month field', week: 'week field', range: 'slider', color: 'colour field' };

// ---- What something is

/** The checkbox or radio button a label stands for, when the page does not show the input itself. */
function hiddenChoice(label) {
  const input = label.control;
  if (!input || tagOf(input) !== 'INPUT' || (input.type !== 'checkbox' && input.type !== 'radio')) return null;
  return input.getClientRects().length === 0 ? input : null;
}

function kindOf(el, tag, style, parentCursor) {
  const role = squash(el.getAttribute('role')).toLowerCase();
  if ((tag === 'A' || tag === 'AREA') && el.hasAttribute('href')) return role === 'button' ? 'button' : 'link';
  if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
  if (tag === 'INPUT') {
    const type = squash(el.getAttribute('type')).toLowerCase() || 'text';
    if (type === 'hidden') return null;
    if (type === 'submit' || type === 'button' || type === 'reset' || type === 'image') return 'button';
    if (type === 'checkbox') return 'checkbox';
    if (type === 'radio') return 'radio';
    if (type === 'file') return 'file';
    return 'field';
  }
  if (tag === 'TEXTAREA') return 'field';
  if (tag === 'SELECT') return 'select';
  if (tag === 'IFRAME' || tag === 'FRAME') return 'frame';
  if (tag === 'LABEL') {
    // Pages often hide a checkbox or a radio button outright and draw their own on its label. The label then stands
    // for it: clicking a label is clicking what it labels.
    const input = hiddenChoice(el);
    return input ? (input.type === 'radio' ? 'radio' : 'checkbox') : null;
  }
  if (el.isContentEditable) return el.parentElement && el.parentElement.isContentEditable ? null : 'field';
  switch (role) {
    case 'button': return 'button';
    case 'link': return 'link';
    case 'checkbox': case 'switch': case 'menuitemcheckbox': return 'checkbox';
    case 'radio': case 'menuitemradio': return 'radio';
    case 'tab': return 'tab';
    case 'menuitem': return 'menu item';
    case 'option': return 'choice';
    case 'treeitem': return 'item';
    case 'combobox': case 'textbox': case 'searchbox': return 'clickable';
  }
  if (el.hasAttribute('onclick')) return 'clickable';
  // Many pages build their controls from plain boxes; the hand cursor is how they tell the person it can be clicked.
  if (style.cursor === 'pointer' && parentCursor !== 'pointer' && tag !== 'BODY' && tag !== 'HTML') return 'clickable';
  return null;
}

/**
 * Text of a node as a label: what the person sees written in it, without the lists of choices and the fields nested
 * inside, and without anything the page keeps out of sight.
 */
function plain(node, depth) {
  if (node.nodeType === 3) return node.nodeValue;
  if (node.nodeType !== 1 || (depth || 0) > 40) return '';
  const tag = tagOf(node);
  if (SKIP.has(tag) || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'INPUT') return '';
  let style = null;
  try { style = styleOf(node); } catch (e) {}
  if (style && (style.display === 'none' || style.visibility === 'hidden')) return '';
  if (tag === 'IMG') return ' ' + (node.getAttribute('alt') || '') + ' ';
  let out = '';
  for (const kid of node.childNodes) out += plain(kid, (depth || 0) + 1);
  return out;
}

function named(el) {
  const direct = squash(el.getAttribute('aria-label'));
  if (direct) return direct;
  const ids = squash(el.getAttribute('aria-labelledby'));
  if (!ids) return '';
  const root = el.getRootNode();
  return squash(ids.split(' ').map((id) => { const other = root.getElementById ? root.getElementById(id) : null; return other ? plain(other) : ''; }).join(' '));
}

function labelOf(el, kind, tag) {
  const control = kind === 'field' || kind === 'select' || kind === 'file' || kind === 'checkbox' || kind === 'radio';
  let label = '';
  if (control) {
    if (el.labels && el.labels.length) label = squash(Array.from(el.labels).map((l) => plain(l)).join(' '));
    if (!label) label = named(el);
    // A checkbox the page draws itself carries its words inside it.
    if (!label && kind !== 'field' && tag !== 'INPUT' && tag !== 'SELECT') label = squash(plain(el));
  } else if (kind !== 'frame') {
    // What is written on a button or a link comes before any name given to it out of sight: the words the person
    // sees on the page are the words they are asked to approve.
    if (tag === 'INPUT') label = squash(el.value) || squash(el.getAttribute('alt')) || (el.type === 'submit' ? 'Submit' : el.type === 'reset' ? 'Reset' : '');
    else label = squash(plain(el));
    if (!label) label = named(el);
  }
  if (!label) label = squash(el.getAttribute('placeholder')) || squash(el.getAttribute('title')) || squash(el.getAttribute('alt')) || squash(el.getAttribute('name'));
  return clip(label, 80);
}

/** The question a checkbox or a radio button answers: the legend of its group. */
function groupOf(el) {
  const group = el.closest ? el.closest('fieldset, [role="radiogroup"], [role="group"]') : null;
  if (!group) return '';
  if (tagOf(group) === 'FIELDSET') { const legend = group.querySelector('legend'); if (legend) return clip(plain(legend), 80); }
  return clip(named(group), 80);
}

/** Where a link goes, if following it is nothing more than going to another address. */
function plainTarget(el) {
  const tag = tagOf(el);
  if ((tag !== 'A' && tag !== 'AREA') || !el.hasAttribute('href') || el.hasAttribute('download')) return null;
  if (squash(el.getAttribute('role')).toLowerCase() === 'button') return null;
  let to, here;
  try { to = new URL(el.href, el.ownerDocument.baseURI); here = new URL(el.ownerDocument.location.href); } catch (e) { return null; }
  if (to.protocol !== 'http:' && to.protocol !== 'https:') return null;
  // href="#" and links to the page itself are buttons in disguise: only a script gives them something to do.
  if (to.origin === here.origin && to.pathname === here.pathname && to.search === here.search && to.hash.length <= 1) return null;
  return to.href;
}

function shortTarget(href) {
  try {
    const to = new URL(href), here = new URL(location.href);
    const rest = to.pathname + to.search + to.hash;
    return clip(to.origin === here.origin ? rest : to.host + (rest === '/' ? '' : rest), 70);
  } catch (e) { return clip(href, 70); }
}

const isSecret = (el) => {
  if (tagOf(el) !== 'INPUT') return false;
  if (squash(el.getAttribute('type')).toLowerCase() === 'password') return true;
  if (/(current|new)-password/i.test(el.getAttribute('autocomplete') || '')) return true;
  const security = styleOf(el).webkitTextSecurity;
  return !!security && security !== 'none';
};
const isCard = (el) => {
  const hint = [el.getAttribute('autocomplete'), el.getAttribute('name'), el.id].join(' ');
  return /\bcc-(number|csc|exp)/i.test(hint) || /(card[-_ ]?num|cardnumber|cc[-_ ]?num|\bcvc\b|\bcvv\b|\bcsc\b|security[-_ ]?code)/i.test(hint);
};

function infoOf(rec, n) {
  const el = rec.el, kind = rec.kind, tag = tagOf(el);
  const info = { n, kind, name: kind, label: labelOf(el, kind, tag), connected: el.isConnected };
  info.disabled = !!el.disabled || el.getAttribute('aria-disabled') === 'true' || !!(el.matches && el.matches(':disabled'));
  if (kind === 'link') { const to = plainTarget(el); if (to) info.plain = to; }
  if (kind === 'button' || kind === 'clickable' || kind === 'menu item') {
    const open = el.getAttribute('aria-expanded');
    if (open === 'true' || open === 'false') info.expanded = open === 'true';
    if (tag === 'SUMMARY' && el.parentElement && tagOf(el.parentElement) === 'DETAILS') info.expanded = !!el.parentElement.open;
  }
  if (kind === 'tab' || kind === 'choice' || kind === 'item') info.selected = el.getAttribute('aria-selected') === 'true';
  if (kind === 'checkbox' || kind === 'radio') {
    info.name = kind === 'radio' ? 'radio button' : 'checkbox';
    const input = tag === 'INPUT' ? el : tag === 'LABEL' ? el.control : null;
    info.checked = input ? !!input.checked : el.getAttribute('aria-checked') === 'true';
    if (input && input.disabled) info.disabled = true;
    info.group = groupOf(el);
  }
  if (kind === 'field') {
    const type = tag === 'INPUT' ? (squash(el.getAttribute('type')).toLowerCase() || 'text') : '';
    info.name = tag === 'INPUT' ? (FIELD_NAMES[type] || 'text field') : tag === 'TEXTAREA' ? 'text area' : 'text box';
    info.password = isSecret(el);
    if (info.password) info.name = 'password field';
    info.payment = !info.password && isCard(el);
    info.readonly = !!el.readOnly;
    info.required = !!el.required || el.getAttribute('aria-required') === 'true';
    info.invalid = el.getAttribute('aria-invalid') === 'true';
    info.value = info.password ? '' : clip(tag === 'INPUT' || tag === 'TEXTAREA' ? el.value : plain(el), 100);
    info.filled = tag === 'INPUT' || tag === 'TEXTAREA' ? el.value !== '' : squash(plain(el)) !== '';
  }
  if (kind === 'select') {
    info.name = 'drop-down list';
    info.multiple = !!el.multiple;
    info.required = !!el.required;
    const options = Array.from(el.options);
    info.chosen = options.filter((o) => o.selected).map((o) => clip(o.text, 60));
    info.choices = options.filter((o) => !o.disabled).slice(0, 40).map((o) => clip(o.text, 60));
    info.moreChoices = Math.max(0, options.filter((o) => !o.disabled).length - 40);
  }
  if (kind === 'file') {
    info.name = 'file input';
    info.multiple = !!el.multiple;
    info.accept = squash(el.getAttribute('accept'));
    info.files = Array.from(el.files || []).map((f) => f.name);
  }
  if (kind === 'frame') {
    info.label = clip(squash(el.getAttribute('title')) || named(el) || squash(el.getAttribute('name')), 80);
    let src = '';
    try { src = new URL(el.getAttribute('src') || '', el.ownerDocument.baseURI).href; } catch (e) {}
    if (/^https?:/i.test(src)) info.frame = src;
  }
  return info;
}

/** One line of the list the agent reads. */
function lineOf(info) {
  let line = '[' + info.n + '] ' + info.name + (info.label ? ' ' + quote(info.label) : ' (no name)');
  if (info.group) line += ' in ' + quote(info.group);
  if (info.plain) line += ' → ' + shortTarget(info.plain);
  if (info.kind === 'checkbox') line += info.checked ? ', checked' : ', not checked';
  if (info.kind === 'radio') line += info.checked ? ', chosen' : ', not chosen';
  if (info.kind === 'field') {
    if (info.password) line += ' (the person fills this in themselves)';
    else line += info.filled ? ', holds ' + quote(info.value) : ', empty';
    if (info.required) line += ', required';
    if (info.readonly) line += ', cannot be changed';
    if (info.invalid) line += ', marked as wrong';
  }
  if (info.kind === 'select') {
    line += info.chosen.length ? ', set to ' + info.chosen.map(quote).join(' and ') : ', nothing chosen';
    if (info.required) line += ', required';
    line += '. Choices: ' + info.choices.join(' | ') + (info.moreChoices ? ' | … and ' + info.moreChoices + ' more' : '');
  }
  if (info.kind === 'file') {
    line += info.files.length ? ', holds ' + info.files.join(', ') : ', no file chosen';
    if (info.accept) line += ' (takes ' + clip(info.accept, 60) + ')';
  }
  if (info.kind === 'frame') line += info.frame ? ' → ' + clip(info.frame, 120) + ' (a page inside this one; open its address to read it)' : ' (a page inside this one that cannot be read)';
  if (info.expanded === true) line += ', open';
  if (info.expanded === false) line += ', closed';
  if (info.selected) line += ', selected';
  if (info.disabled) line += ', disabled';
  return line;
}

const phrase = (info) => (info.label ? quote(info.label) : 'the unnamed ' + info.name);

// ---- Reading the page

/** Whether something stays put while the page scrolls under it: a bar at the top, a banner over the page. */
function pinned(el) {
  for (let up = el, steps = 0; up && steps < 12; up = up.parentElement, steps++) {
    const position = styleOf(up).position;
    if (position === 'fixed' || position === 'sticky') return true;
  }
  return false;
}

/** What sits near the top of what the person would see, to tell where in the text the window is scrolled to. */
function viewportMarks() {
  const marks = new Set();
  for (const across of [0.5, 0.25, 0.75]) {
    const under = document.elementsFromPoint(innerWidth * across, innerHeight * 0.3).slice(0, 6);
    const el = under.find((candidate) => !pinned(candidate));
    // Its parents too: the thing itself may be something the reading skips, such as a drawing.
    for (let up = el, steps = 0; up && steps < 3; up = up.parentElement, steps++) marks.add(up);
  }
  return marks;
}

function scan() {
  const parts = [];
  const records = [];
  const marks = viewportMarks();
  let length = 0, breaks = 0, gap = false, viewportAt = -1, truncated = false;
  const put = (s) => { parts.push(s); length += s.length; };
  /** Add running text, with white space folded as the page folds it. Answers where it went. */
  const say = (text) => {
    const body = text.replace(/\s+/g, ' ').trim();
    if (!body) { if (text) gap = true; return length; }
    if (breaks && length) put(breaks > 1 ? '\n\n' : '\n');
    else if ((gap || /^\s/.test(text)) && length && !breaks) put(' ');
    breaks = 0;
    gap = /\s$/.test(text);
    const at = length;
    put(body);
    return at;
  };
  /** Text whose line breaks mean something: code, and pages that keep the writer's own lines. */
  const sayKept = (text) => {
    const body = text.replace(/\r/g, '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
    if (!body.trim()) { gap = true; return; }
    if (breaks && length) put(breaks > 1 ? '\n\n' : '\n');
    breaks = 0;
    gap = false;
    put(length ? body : body.replace(/^\s+/, ''));
  };
  const apart = (n) => { if (n > breaks) breaks = n; gap = false; };

  const walk = (node, context) => {
    if (truncated) return;
    if (node.nodeType === 3) {
      if (context.visible) (context.kept ? sayKept : say)(node.nodeValue);
      return;
    }
    if (node.nodeType !== 1 || context.depth > 300) return;
    const el = node, tag = tagOf(el);
    if (SKIP.has(tag)) return;
    if (length > 400000 || records.length >= 4000) { truncated = true; return; }
    let style;
    try { style = styleOf(el); } catch (e) { return; }
    if (!style || style.display === 'none') return;
    if (marks.has(el)) viewportAt = Math.max(viewportAt, length);
    if (tag === 'BR') { apart(1); return; }
    if (tag === 'HR') { apart(2); return; }
    const display = style.display;
    const block = !(display.startsWith('inline') || display === 'contents' || display === 'table-cell' || display === 'ruby' || display === 'ruby-text');
    const visible = style.visibility === 'visible';
    if (block) apart(APART.has(tag) ? 2 : 1);
    else if (display === 'table-cell' && el.previousElementSibling) { gap = true; say('|'); gap = true; }

    // Inside something that is already listed, a hand cursor says nothing new.
    let kind = visible ? kindOf(el, tag, style, context.within ? 'pointer' : context.cursor) : null;
    if (kind === 'frame') {
      // A frame from the same site is part of the page and is read in place. Any other can only be named.
      let inner = null;
      try { inner = el.contentDocument; } catch (e) {}
      // A frame that has not loaded what it points at still shows the blank it began with; that is not its page.
      const blank = inner && inner.location.href === 'about:blank' && /^https?:/i.test(el.src || '') && !inner.body.childNodes.length;
      if (inner && inner.body && !blank) {
        walk(inner.body, { visible, cursor: '', within: false, kept: false, depth: context.depth + 1 });
        if (block) apart(1);
        return;
      }
    }
    // Something with no box is not there to be clicked. A file input is the exception: pages hide it behind a button.
    if (kind && kind !== 'file' && el.getClientRects().length === 0) kind = null;
    if (kind === 'frame' || kind === 'link' || kind === 'button' || kind === 'clickable') {
      // Nor is something with nothing to it: an empty link, or the one-dot frames pages use to keep count of visitors.
      const box = el.getBoundingClientRect();
      const empty = () => !squash(el.textContent) && !el.querySelector('img, svg') && !named(el);
      if (kind === 'frame' ? box.width < 40 || box.height < 20 : (box.width === 0 || box.height === 0) && empty()) kind = null;
    }
    if (kind) {
      gap = true;
      const at = say('[' + (records.length + 1) + ']');
      gap = true;
      records.push({ el, kind, at });
    }
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || kind === 'frame') {
      if (block) apart(1);
      return;
    }
    if (tag === 'IMG') {
      const alt = squash(el.getAttribute('alt'));
      if (alt && visible) say(' (image: ' + clip(alt, 100) + ') ');
      return;
    }
    if (/^H[1-6]$/.test(tag) && visible) { say('#'.repeat(Number(tag[1]))); gap = true; }
    if (tag === 'LI' && visible) { say('-'); gap = true; }
    const within = context.within || kind === 'link' || kind === 'button' || kind === 'clickable';
    const inside = { visible, cursor: style.cursor, within, kept: /^pre/.test(style.whiteSpace || '') && style.whiteSpace !== 'pre-line', depth: context.depth + 1 };
    let kids = el.childNodes;
    if (el.shadowRoot) kids = el.shadowRoot.childNodes;
    else if (tag === 'SLOT') { const assigned = el.assignedNodes({ flatten: true }); if (assigned.length) kids = assigned; }
    else if (tag === 'DETAILS' && !el.open) kids = Array.from(el.children).filter((kid) => tagOf(kid) === 'SUMMARY').slice(0, 1);
    for (const kid of kids) walk(kid, inside);
    if (block) apart(APART.has(tag) ? 2 : 1);
  };
  if (document.body) walk(document.body, { visible: true, cursor: '', within: false, kept: false, depth: 0 });

  // File inputs the walk could not reach, because the page keeps them out of sight, are still what an upload needs.
  const known = new Set(records.map((rec) => rec.el));
  for (const input of document.querySelectorAll('input[type="file"]')) {
    if (known.has(input) || records.length >= 4000) continue;
    gap = true;
    const at = say('[' + (records.length + 1) + ']');
    gap = true;
    records.push({ el: input, kind: 'file', at });
  }
  return { text: parts.join(''), records, viewportAt, truncated };
}

/** Signs that the page is checking for a human, which the person has to answer. */
function humanCheck() {
  const found = document.querySelectorAll('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare.com"], iframe[src*="captcha"], .g-recaptcha, .h-captcha, .cf-turnstile, #challenge-form, #captcha, [class*="captcha" i]');
  for (const el of found) {
    if (el.closest('.grecaptcha-badge')) continue;
    const box = el.getBoundingClientRect();
    if (box.width >= 100 && box.height >= 40) return true;
  }
  return /^(just a moment|attention required|verify(ing)? (that )?you are human)/i.test(document.title || '');
}

/**
 * The page as the agent reads it: one stretch of its text, and the elements whose marks fall in that stretch.
 * `mode` says which stretch: "start", "offset" (from `offset`), "viewport" (where the window is scrolled to),
 * "element" (keep the stretch shown last if element `element` is in it, else move to it) or "keep".
 */
async function view(args) {
  const had = Array.isArray(S.records);
  const focus = had && args.element ? (S.records[args.element - 1] || {}).el : null;
  const page = scan();
  S.records = page.records;
  const total = page.text.length, limit = args.limit || 8000;
  let start = 0;
  if (args.mode === 'offset') start = args.offset || 0;
  else if (args.mode === 'viewport') {
    const scrolled = scrollState();
    if (page.viewportAt >= 0) start = page.viewportAt > 400 ? page.viewportAt - 400 : 0;
    // Nothing recognisable under the top of the window: go by how far down it is scrolled.
    else if (scrolled.most > 0) start = Math.floor(total * scrolled.top / (scrolled.most + innerHeight));
  }
  else if (had && (args.mode === 'element' || args.mode === 'keep')) {
    start = args.last || 0;
    const rec = focus ? page.records.find((r) => r.el === focus) : null;
    if (rec && (rec.at < start || rec.at >= start + limit)) start = Math.max(0, rec.at - 1500);
  }
  if (start >= total) start = Math.max(0, total - limit);
  if (start < 0) start = 0;
  if (start > 0 && args.mode !== 'offset') { const line = page.text.indexOf('\n', start); if (line >= 0 && line - start < 300) start = line + 1; }
  while (start < total && page.text[start] === '\n') start++;
  let end = Math.min(total, start + limit);
  if (end < total) {
    const line = page.text.lastIndexOf('\n', end);
    if (line > start + limit * 0.6) end = line;
    else { const space = page.text.lastIndexOf(' ', end); if (space > start + limit * 0.8) end = space; }
  }
  const within = [];
  page.records.forEach((rec, index) => { if (rec.at >= start && rec.at < end) within.push(index); });
  const shown = within.slice(0, 150);
  return {
    title: clip(document.title, 200), url: location.href, total, start, end,
    text: page.text.slice(start, end),
    lines: shown.map((index) => lineOf(infoOf(page.records[index], index + 1))),
    unlisted: within.length - shown.length,
    elsewhere: page.records.length - within.length,
    truncated: page.truncated,
    password: page.records.some((rec) => rec.kind === 'field' && isSecret(rec.el)),
    human: humanCheck(),
    scrolled: scrollState(),
  };
}

// ---- Acting

function find(n) {
  if (!Array.isArray(S.records)) return { error: 'This page has changed since your last view of it. Read the page first: element numbers come from the newest view.' };
  const rec = S.records[n - 1];
  if (!rec) return { error: 'There is no element ' + n + ' in the newest view of this page; it has ' + S.records.length + '. Read the page to see what is there now.' };
  if (!rec.el.isConnected) return { error: 'Element ' + n + ' is no longer on the page; the page has changed. Read it again to see it as it is now.' };
  return { rec };
}

function matchOption(el, wanted) {
  const options = Array.from(el.options).filter((o) => !o.disabled);
  const want = squash(wanted).toLowerCase();
  const text = (o) => squash(o.text).toLowerCase();
  let hits = options.filter((o) => text(o) === want);
  if (!hits.length) hits = options.filter((o) => squash(o.value).toLowerCase() === want);
  if (!hits.length) { const starts = options.filter((o) => text(o).startsWith(want)); if (starts.length === 1) hits = starts; }
  if (!hits.length) { const holds = options.filter((o) => text(o).includes(want)); if (holds.length === 1) hits = holds; }
  if (hits.length) return { option: hits[0] };
  const offered = options.slice(0, 40).map((o) => clip(o.text, 60)).join(' | ');
  return { error: 'There is no choice ' + quote(clip(wanted, 60)) + ' in that list. It has: ' + offered + (options.length > 40 ? ' | … and ' + (options.length - 40) + ' more' : '') + '.' };
}

/** What an element is, for putting an action on it into words and for deciding whether it may be done. */
async function describe(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  const info = infoOf(found.rec, args.n);
  info.ok = true;
  if (info.kind === 'select' && args.option != null) {
    const match = matchOption(found.rec.el, args.option);
    if (match.error) info.optionError = match.error; else info.option = clip(match.option.text, 80);
  }
  return info;
}

function fire(el, type, Kind, extra) {
  const view = el.ownerDocument.defaultView || window;
  return el.dispatchEvent(new Kind(type, Object.assign({ bubbles: true, cancelable: true, composed: true, view }, extra || {})));
}

/** Click as a person's pointer would: press, focus, release, click. Pages listen for any of these. */
function press(el) {
  if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
  const box = el.getBoundingClientRect();
  const at = { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, button: 0 };
  const pointer = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, at);
  fire(el, 'pointerover', PointerEvent, pointer);
  fire(el, 'mouseover', MouseEvent, at);
  fire(el, 'pointerdown', PointerEvent, Object.assign({ buttons: 1 }, pointer));
  fire(el, 'mousedown', MouseEvent, Object.assign({ buttons: 1 }, at));
  if (typeof el.focus === 'function') el.focus({ preventScroll: true });
  fire(el, 'pointerup', PointerEvent, pointer);
  fire(el, 'mouseup', MouseEvent, at);
  if (typeof el.click === 'function') el.click(); else fire(el, 'click', MouseEvent, Object.assign({ detail: 1 }, at));
}

async function click(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  const el = found.rec.el, info = infoOf(found.rec, args.n);
  // A plain link is followed by loading its address, so that following one can never do more than that.
  if (info.plain) return { ok: true, navigate: info.plain, did: 'Followed the link ' + phrase(info) + '.' };
  if (info.frame) return { ok: true, navigate: info.frame, did: 'Opened the page inside the frame ' + phrase(info) + '.' };
  press(el);
  let did = 'Clicked ' + phrase(info) + '.';
  if (info.kind === 'checkbox' || info.kind === 'radio') {
    const now = infoOf(found.rec, args.n).checked;
    did = (info.kind === 'radio' ? (now ? 'Chose ' : 'Clicked ') : now ? 'Checked ' : 'Unchecked ') + phrase(info) + '.';
  }
  return { ok: true, did };
}

/** Set a field's value the way typing does, so pages built with React and its like notice the change. */
function setValue(el, value) {
  const proto = tagOf(el) === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value');
  if (setter && setter.set) setter.set.call(el, value); else el.value = value;
}

async function type(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  const el = found.rec.el, tag = tagOf(el), info = infoOf(found.rec, args.n);
  // Checked by the app before it gets here, and once more where the typing happens.
  if (info.kind !== 'field' || info.password || info.payment || info.disabled || info.readonly) return { ok: false, error: 'Element ' + args.n + ' cannot be typed into.' };
  const text = String(args.text == null ? '' : args.text);
  if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
  el.focus({ preventScroll: true });
  let holds;
  if (tag === 'INPUT' || tag === 'TEXTAREA') {
    setValue(el, text);
    fire(el, 'input', InputEvent, { inputType: 'insertText', data: text, cancelable: false });
    fire(el, 'change', Event, { cancelable: false });
    holds = el.value;
  } else {
    // A text box the page draws itself: replace what it holds through the editing commands, which its editor follows.
    const doc = el.ownerDocument, selection = doc.getSelection(), range = doc.createRange();
    range.selectNodeContents(el);
    selection.removeAllRanges();
    selection.addRange(range);
    const done = text === '' ? doc.execCommand('delete') : doc.execCommand('insertText', false, text);
    if (!done || squash(plain(el)) !== squash(text)) {
      el.textContent = text;
      fire(el, 'input', InputEvent, { inputType: 'insertText', data: text, cancelable: false });
    }
    holds = plain(el);
  }
  let did = text === '' ? 'Cleared ' + phrase(info) + '.' : 'Typed ' + quote(clip(text, 80)) + ' into ' + phrase(info) + '.';
  if (squash(holds) !== squash(text)) did += ' The field now holds ' + quote(clip(holds, 80)) + ', which is not what was typed: it may take another format.';
  if (args.submit) {
    const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
    const goOn = fire(el, 'keydown', KeyboardEvent, key);
    fire(el, 'keypress', KeyboardEvent, key);
    // Return in a form's field sends the form, by way of its button when it has one.
    if (goOn && el.form && tag !== 'TEXTAREA') {
      const button = Array.from(el.form.querySelectorAll('button, input[type="submit"], input[type="image"]')).find((b) => (tagOf(b) === 'INPUT' || b.type === 'submit') && !b.disabled);
      if (button) button.click(); else el.form.requestSubmit();
    }
    fire(el, 'keyup', KeyboardEvent, key);
    did += ' Pressed Return.';
  }
  return { ok: true, did };
}

async function select(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  const el = found.rec.el, info = infoOf(found.rec, args.n);
  if (info.kind !== 'select' || info.disabled) return { ok: false, error: 'Element ' + args.n + ' is not a list that can be chosen from.' };
  const match = matchOption(el, args.option);
  if (match.error) return { ok: false, error: match.error };
  if (el.multiple) match.option.selected = true; else el.selectedIndex = match.option.index;
  fire(el, 'input', Event, { cancelable: false });
  fire(el, 'change', Event, { cancelable: false });
  return { ok: true, did: 'Chose ' + quote(clip(match.option.text, 80)) + ' in ' + phrase(info) + '.' };
}

/** Open a file input's chooser. The app answers it with the file. */
async function chooseFile(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  if (found.rec.kind !== 'file' || found.rec.el.disabled) return { ok: false, error: 'Element ' + args.n + ' is not a file input that can be used.' };
  found.rec.el.click();
  return { ok: true, did: '' };
}

async function files(args) {
  const found = find(args.n);
  if (found.error) return { ok: false, error: found.error };
  const info = infoOf(found.rec, args.n);
  return { ok: true, did: phrase(info), names: Array.from(found.rec.el.files || []).map((f) => f.name) };
}

/** The part of the page that scrolls: the window, or, where the page is an app in a fixed frame, its biggest pane. */
function scroller() {
  const root = document.scrollingElement || document.documentElement;
  if (root.scrollHeight > innerHeight + 4) return root;
  let best = null, area = 0;
  const all = document.querySelectorAll('main, section, article, div, ul, ol, table, aside, nav');
  for (let i = 0; i < all.length && i < 6000; i++) {
    const el = all[i];
    if (el.scrollHeight <= el.clientHeight + 20 || el.clientHeight < 80) continue;
    const overflow = styleOf(el).overflowY;
    if (overflow !== 'auto' && overflow !== 'scroll' && overflow !== 'overlay') continue;
    const size = el.clientWidth * el.clientHeight;
    if (size > area) { area = size; best = el; }
  }
  return best || root;
}

function scrollState() {
  const el = scroller();
  const height = el === (document.scrollingElement || document.documentElement) ? innerHeight : el.clientHeight;
  return { top: Math.round(el.scrollTop), most: Math.max(0, Math.round(el.scrollHeight - height)) };
}

async function scroll(args) {
  const el = scroller();
  const height = el === (document.scrollingElement || document.documentElement) ? innerHeight : el.clientHeight;
  const before = el.scrollTop;
  el.scrollTo({ top: before + args.dy * height * 0.85, behavior: 'instant' });
  return { ok: true, did: '', moved: Math.abs(el.scrollTop - before) > 1 };
}

/** A cheap fingerprint of the page, to tell when it has stopped changing. */
async function signature() {
  const body = document.body;
  return document.readyState + '|' + location.href + '|' + (body ? body.getElementsByTagName('*').length + '/' + (body.innerText || '').length : 0);
}

const pi2 = { view, describe, click, type, select, chooseFile, files, scroll, signature };
"""#
}
