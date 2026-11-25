// One completion controller per editor. LiveView owns the field and its form;
// the hook owns the suggestion list and the inline hint in an ignored layer.
function parseMeta(raw) {
  let meta;
  try { meta = JSON.parse(raw); } catch { /* No catalog yet. */ }
  return Object.fromEntries(
    ["commands", "thinking_levels", "attention_args", "archive_args", "models"].map(key =>
      [key, Array.isArray(meta?.[key]) ? meta[key] : []]
    )
  );
}

function tokenAtCursor(value, cursor) {
  let start = cursor;
  while (start > 0 && !/\s/.test(value[start - 1])) start -= 1;
  let end = cursor;
  while (end < value.length && !/\s/.test(value[end])) end += 1;
  return { start, end, prefix: value.slice(start, cursor) };
}

function slashLine(value) {
  const line = value.trim();
  return line.startsWith("/") && !line.startsWith("//") && !line.includes("\n");
}

const staticArgs = ["/thinking", "/model", "/attention", "/archive", "/fork"];

export function composerContext(value, cursor, explicit = false, allowCommands = true) {
  if (allowCommands && slashLine(value) && !value.slice(0, cursor).trimStart().includes("\n")) {
    const leading = value.length - value.trimStart().length;
    const name = value.trimStart().match(/^\S+/)[0];
    const end = leading + name.length;
    if (cursor >= leading && cursor <= end) {
      return { mode: "command", start: leading, end, prefix: value.slice(leading, cursor) };
    }

    const cmd = name.toLowerCase();
    const rest = value.slice(end);
    const start = end + rest.length - rest.trimStart().length;
    const prefix = value.slice(start, cursor);
    if (cursor >= start && cmd === "/cwd") {
      return { mode: "path", kind: "directory", start, end: Math.max(start, value.trimEnd().length), prefix };
    }
    if (cursor >= start && staticArgs.includes(cmd) && !/\s/.test(prefix)) {
      return { mode: "argument", cmd, start, end: tokenAtCursor(value, cursor).end, prefix };
    }
  }

  const token = tokenAtCursor(value, cursor);
  if (token.prefix.startsWith("@")) {
    return { ...token, mode: "path", kind: "workspace_file", prefix: token.prefix.slice(1) };
  }
  if (token.prefix && (explicit || token.prefix.includes("/") || token.prefix === "~")) {
    // Don't treat the leading slash of an escaped command as a filesystem path.
    if (token.start === value.length - value.trimStart().length && token.prefix.startsWith("/")) return null;
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(token.prefix)) return null;
    const shell = /^(?:\/(?:steer|follow-up)\s+)?!/i.test(value.trimStart());
    return { ...token, mode: "path", kind: "path", shell };
  }
  return null;
}

function localItems(ctx, meta) {
  const q = ctx.prefix.toLowerCase();
  if (ctx.mode === "command") {
    const prefix = meta.commands.filter(cmd => cmd.name.startsWith(q));
    const fuzzy = meta.commands.filter(cmd => !cmd.name.startsWith(q) && cmd.name.includes(q.slice(1)));
    return [...prefix, ...fuzzy].map(cmd => ({
      value: cmd.name, label: cmd.usage || cmd.name, description: cmd.description,
      takesArg: cmd.takes_arg
    }));
  }
  if (ctx.cmd === "/model") {
    const models = meta.models.filter(m => m.id.toLowerCase().includes(q) || m.label?.toLowerCase().includes(q));
    return [...models.filter(m => m.id.toLowerCase().startsWith(q)),
      ...models.filter(m => !m.id.toLowerCase().startsWith(q))].slice(0, 30).map(m => ({
      value: m.id, description: m.label || m.provider
    }));
  }
  const choices = {
    "/thinking": meta.thinking_levels,
    "/attention": meta.attention_args,
    "/archive": meta.archive_args,
    "/fork": ["cancel"]
  };
  const descriptions = {
    "/thinking": { default: "Reasoning effort" },
    "/attention": { on: "Mark for attention", off: "Mark as read" },
    "/archive": { force: "Stop work and archive", off: "Restore from archive" },
    "/fork": { cancel: "Cancel active fork edit" }
  }[ctx.cmd];
  return (choices[ctx.cmd] || []).filter(value => value.startsWith(q)).map(value => ({
    value, description: descriptions[value] || descriptions.default
  }));
}

export function completionEdit(value, ctx, item) {
  let inserted = item.value;
  const directory = ctx.mode === "path" && item.kind === "dir";
  if (directory && ctx.kind === "workspace_file") inserted = `@${inserted}`;
  // Keep an existing argument (and its separating space) when editing the command name.
  const commandArg = ctx.mode === "command" && item.takesArg && ctx.end === value.length;
  if (commandArg) inserted += " ";
  return {
    value: value.slice(0, ctx.start) + inserted + value.slice(ctx.end),
    cursor: ctx.start + inserted.length,
    chain: commandArg || directory
  };
}

function create(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text) node.textContent = text;
  return node;
}

// Copy the native field's text metrics. The hidden mirror wraps only the real
// draft; an absolutely positioned suffix cannot wrap it or make the field grow.
const textMetrics = ["font", "letterSpacing", "wordSpacing", "tabSize", "textAlign",
  "textTransform", "direction", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft"];

class CompletionView {
  constructor(input, layer, composer, onSelect) {
    this.input = input;
    this.composer = composer;
    this.layer = layer;
    this.popup = create("div", "completion-popup");
    this.popup.id = `${layer.id}-list`;
    this.popup.setAttribute("role", "listbox");
    this.popup.setAttribute("aria-label", composer ? "Command and path suggestions" : "Directory suggestions");
    this.popup.hidden = true;
    this.popup.addEventListener("mousedown", event => event.preventDefault());
    this.popup.addEventListener("click", event => {
      const option = event.target.closest(".completion-item");
      if (option) onSelect(Number(option.dataset.index));
    });

    this.ghost = create("div", "completion-ghost");
    this.ghost.setAttribute("aria-hidden", "true");
    this.mirror = create("div", composer ? "completion-mirror is-multiline" : "completion-mirror");
    this.draft = document.createTextNode("");
    this.suffix = create("span", "completion-suffix");
    this.mirror.append(this.draft, this.suffix);
    this.ghost.append(this.mirror);
    this.ghost.hidden = true;
    layer.replaceChildren(this.ghost, this.popup);
  }

  setItems(items) {
    this.popup.replaceChildren(...items.map((item, index) => {
      const row = create("button", "completion-item");
      row.id = `${this.popup.id}-${index}`;
      row.dataset.index = index;
      row.type = "button";
      row.tabIndex = -1;
      row.setAttribute("role", "option");
      const label = item.label || item.value;
      const path = item.kind === "dir" || item.kind === "file";
      const split = path ? label.lastIndexOf("/", label.length - (label.endsWith("/") ? 2 : 1)) + 1 : 0;
      const name = create("span", "completion-item-label mono", label.slice(split));
      const detail = label.slice(0, split) || item.description;
      const body = create("span", "completion-item-body");
      body.append(name);
      if (detail) body.append(create("span", "completion-item-desc", detail));
      row.append(body);
      if (path) row.append(create("span", "completion-item-kind", item.kind === "dir" ? "Folder" : "File"));
      row.title = path ? item.value : [label, detail].filter(Boolean).join(" — ");
      if (path) row.setAttribute("aria-label", `${item.value} (${item.kind === "dir" ? "folder" : "file"})`);
      return row;
    }));
    this.popup.scrollTop = 0;
  }

  select(index) {
    for (const [i, row] of Array.from(this.popup.children).entries()) {
      row.setAttribute("aria-selected", String(i === index));
    }
  }

  layout(index, hint) {
    const field = this.input.getBoundingClientRect();
    const viewport = window.visualViewport;
    const shell = this.input.closest(".screen");
    const screen = shell?.getBoundingClientRect();
    const header = shell?.querySelector(".app-bar")?.getBoundingClientRect();
    const top = Math.max(viewport?.offsetTop ?? 0, header?.bottom ?? screen?.top ?? 0) + 6;
    const bottom = Math.min((viewport?.offsetTop ?? 0) + (viewport?.height ?? window.innerHeight),
      screen?.bottom ?? Infinity) - 6;
    const left = Math.max(field.left, (viewport?.offsetLeft ?? 0) + 4);
    const right = Math.min(field.right, (viewport?.offsetLeft ?? 0) + (viewport?.width ?? window.innerWidth) - 4);
    const reply = this.composer && this.input.closest(".reply")?.getBoundingClientRect();
    const aboveEdge = reply && reply.top - top >= 92 ? reply.top : field.top;
    const above = aboveEdge - top - 6;
    const below = bottom - field.bottom - 6;
    const openUp = this.composer ? above >= 44 || above > below : below < 100 && above > below;
    const room = openUp ? above : below;
    const active = this.popup.children[index];
    this.popup.hidden = !active || room < 38 || field.top >= bottom || field.bottom <= top || right <= left;

    if (!this.popup.hidden) {
      Object.assign(this.popup.style, {
        top: `${openUp ? aboveEdge - 6 : field.bottom + 6}px`,
        left: `${left}px`, width: `${right - left}px`,
        maxHeight: `min(16rem, ${room}px)`,
        transform: openUp ? "translateY(-100%)" : "none"
      });
      this.input.setAttribute("aria-activedescendant", active.id);
      // Never scroll the page, transcript, or mobile viewport to reveal a row.
      const row = active.getBoundingClientRect();
      const list = this.popup.getBoundingClientRect();
      if (row.top < list.top + 1) this.popup.scrollTop += row.top - list.top - 1;
      if (row.bottom > list.bottom - 1) this.popup.scrollTop += row.bottom - list.bottom + 1;
    } else {
      this.input.removeAttribute("aria-activedescendant");
    }
    this.layoutGhost(!this.popup.hidden ? hint : "");
  }

  layoutGhost(hint) {
    this.ghost.hidden = !hint;
    if (!hint) return;
    const input = this.input;
    const style = getComputedStyle(input);
    for (const key of textMetrics) this.mirror.style[key] = style[key];
    Object.assign(this.ghost.style, {
      left: `${input.clientLeft}px`, top: `${input.clientTop}px`,
      width: `${input.clientWidth}px`, height: `${input.clientHeight}px`
    });
    this.mirror.style.transform = `translate(${-input.scrollLeft}px, ${-input.scrollTop}px)`;
    this.draft.data = input.value.endsWith("\n") ? `${input.value}\u200b` : input.value;
    this.suffix.textContent = hint;

    // A long hint belongs in the list, not on a phantom line in the editor.
    const box = this.ghost.getBoundingClientRect();
    const text = this.suffix.getBoundingClientRect();
    // The line box includes leading that native inputs may clip when scrolled.
    const leading = Math.max(0, (parseFloat(style.lineHeight) - parseFloat(style.fontSize)) / 2) || 0;
    if (text.left < box.left || text.right > box.right - parseFloat(style.paddingRight) ||
        text.top + leading < box.top || text.bottom - leading > box.bottom) this.ghost.hidden = true;
  }

  close() {
    this.popup.hidden = true;
    this.ghost.hidden = true;
    this.input.removeAttribute("aria-activedescendant");
  }
}

let lookupSeq = 0;

export class Completer {
  constructor(hook, input, options = {}) {
    this.hook = hook;
    this.input = input;
    this.composer = !options.kind;
    this.kind = options.kind;
    this.event = options.event || "complete_path";
    this.items = [];
    this.controller = new AbortController();
    const listen = (target, name, fn, opts = {}) =>
      target?.addEventListener(name, fn, { ...opts, signal: this.controller.signal });
    const layer = document.getElementById(`${input.id}-completion`);
    this.view = new CompletionView(input, layer, this.composer, index => this.accept(index));
    this.refresh();

    listen(input, "input", () => { if (!this.accepting) this.update(); });
    listen(input, "blur", () => { this.composing = false; this.dismiss(); });
    listen(input.form, "submit", () => this.dismiss());
    listen(input, "compositionstart", () => {
      this.composing = true;
      if (this.context?.mode === "path") this.update(false, true);
    });
    listen(input, "compositionend", () => { this.composing = false; this.update(false, true); });
    listen(input, "keydown", event => {
      if (this.handleKeydown(event)) event.preventDefault();
    });
    // Input events don't cover moving the caret, tapping, or selecting text.
    listen(document, "selectionchange", () => this.update());
    listen(input, "click", () => this.update());
    listen(input, "select", () => this.update());
    listen(input, "keyup", event => {
      if (["ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"].includes(event.key)) this.update();
    });
    const resize = () => this.scheduleLayout();
    listen(window, "resize", resize);
    listen(window, "scroll", event => { if (event.target !== this.view.popup) resize(); }, { capture: true });
    listen(window.visualViewport, "resize", resize);
    listen(window.visualViewport, "scroll", resize);
    this.observer = new ResizeObserver(resize);
    this.observer.observe(input);
    const reply = input.closest(".reply");
    if (reply) this.observer.observe(reply);
    this.resultsRef = hook.handleEvent("completion_results", payload => this.receive(payload));
  }

  refresh() {
    const raw = this.input.dataset.completionMeta;
    const changed = raw !== this.rawMeta;
    if (changed || !this.meta) this.meta = parseMeta(raw);
    this.rawMeta = raw;
    if (this.snapshot && (changed || !this.isCurrent())) this.update(false, changed);
    else this.scheduleLayout();
  }

  read() {
    const { value, selectionStart: start, selectionEnd: end } = this.input;
    return { value, start, end };
  }

  isCurrent(snapshot = this.snapshot) {
    const { value, start, end } = this.read();
    return document.activeElement === this.input && snapshot?.value === value &&
      snapshot.start === start && snapshot.end === end;
  }

  contextFor({ value, start, end }, explicit) {
    if (start !== end) return null;
    return this.composer ? composerContext(value, start, explicit, this.input.dataset.forkEdit !== "true") : {
      mode: "path", kind: this.kind, prefix: value.slice(0, start), start: 0, end: value.length
    };
  }

  update(explicit = false, force = false) {
    if (document.activeElement !== this.input) return;
    if (!explicit && !force && this.isCurrent()) return;
    const next = this.read();
    const ctx = this.contextFor(next, explicit);
    this.cancelLookup();
    this.snapshot = next;
    this.context = ctx;
    if (!ctx || (ctx.mode === "path" && this.composing)) {
      this.setItems([]);
    } else if (ctx.mode !== "path") {
      this.setItems(localItems(ctx, this.meta));
    } else {
      // While narrowing within the same directory, keep only still-valid
      // prefix matches. Never reuse them across triggers or directory levels.
      const last = this.result;
      const q = ctx.prefix.toLowerCase();
      const parent = prefix => prefix.slice(0, prefix.lastIndexOf("/") + 1);
      const compatible = last?.kind === ctx.kind && last.shell === ctx.shell &&
        q.startsWith(last.prefix) && parent(q) === parent(last.prefix);
      this.setItems(compatible ? last.items.filter(item => item.value.toLowerCase().startsWith(q)) : []);
      const id = ++lookupSeq;
      this.pending = id;
      const run = () => {
        this.timer = null;
        if (this.pending !== id || !this.isCurrent(next)) return;
        this.hook.pushEvent(this.event, {
          lookup_id: id, target_id: this.input.id, kind: ctx.kind, prefix: ctx.prefix, shell: Boolean(ctx.shell)
        }, () => {});
      };
      if (explicit) run();
      else this.timer = window.setTimeout(run, 75);
    }
  }

  receive(payload) {
    const ctx = this.context;
    if (!ctx || this.pending == null || !this.isCurrent() || payload?.target_id !== this.input.id ||
        payload.lookup_id !== this.pending || payload.kind !== ctx.kind || payload.prefix !== ctx.prefix) return;
    this.pending = null;
    const items = Array.isArray(payload.items) ? payload.items.filter(item => typeof item?.value === "string") : [];
    this.result = { kind: ctx.kind, shell: ctx.shell, prefix: ctx.prefix.toLowerCase(), items };
    this.setItems(items, this.items[this.selected]?.value);
  }

  cancelLookup() {
    window.clearTimeout(this.timer);
    this.timer = null;
    this.pending = null;
  }

  setItems(items, preferred) {
    this.items = items;
    const exact = this.context?.prefix.toLowerCase();
    const index = items.findIndex(item => item.value === preferred || (!preferred && item.value.toLowerCase() === exact));
    this.selected = Math.max(0, index);
    this.view.setItems(items);
    this.view.select(this.selected);
    this.layout();
  }

  layout() {
    const active = this.items[this.selected];
    if (!active || !this.isCurrent()) {
      this.view.close();
      return;
    }
    const { prefix } = this.context;
    const end = this.snapshot.start === this.snapshot.value.length;
    const matches = active.value.toLowerCase().startsWith(prefix.toLowerCase());
    this.view.layout(this.selected, end && prefix && matches ? active.value.slice(prefix.length) : "");
  }

  scheduleLayout() {
    if (!this.items.length || this.frame != null) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.layout();
    });
  }

  accept(index = this.selected) {
    const item = this.items[index];
    if (this.composing || !item || !this.isCurrent()) return false;
    const next = completionEdit(this.snapshot.value, this.context, item);
    this.accepting = true;
    this.input.value = next.value;
    this.input.setSelectionRange(next.cursor, next.cursor);
    this.input.dispatchEvent(new Event("input", { bubbles: true }));
    this.accepting = false;
    if (next.chain) this.update(true);
    else this.dismiss();
    return true;
  }

  handleKeydown(event) {
    if (event.defaultPrevented || this.composing || event.isComposing || event.keyCode === 229) return false;
    const current = this.isCurrent();
    const open = current && this.items.length > 0 && !this.view.popup.hidden;
    const modified = event.shiftKey || event.metaKey || event.ctrlKey || event.altKey;
    if (modified) return false;

    if (event.key === "Escape" && (open || this.pending != null)) {
      this.dismiss();
      return true;
    }
    if (open && ["ArrowDown", "ArrowUp"].includes(event.key)) {
      const offset = event.key === "ArrowDown" ? 1 : -1;
      this.selected = (this.selected + offset + this.items.length) % this.items.length;
      this.view.select(this.selected);
      this.layout();
      return true;
    }
    if (event.key === "Tab") {
      if (open) return this.accept();
      if (current && this.context && this.pending == null && !this.items.length) return false;
      if (!this.contextFor(this.read(), true)) return false;
      this.update(true);
      return true;
    }
    if (open && event.key === "ArrowRight" && !this.view.ghost.hidden) return this.accept();

    if (this.composer && this.input.dataset.forkEdit !== "true" && event.key === "Enter" && slashLine(this.input.value)) {
      const line = this.input.value.trim();
      const command = line.split(/\s/, 1)[0].toLowerCase();
      const exact = this.meta.commands.some(cmd => cmd.name === command);
      const item = this.items[this.selected];
      if (open && this.context.mode === "command" && !exact) {
        const execute = !item.takesArg && this.context.end === this.input.value.trimEnd().length &&
          this.snapshot.start === this.context.end;
        if (!this.accept() || !execute) return true;
      } else if (open && this.context.mode === "argument" &&
          item.value.toLowerCase() !== this.context.prefix.toLowerCase()) {
        return this.accept();
      }
      event.preventDefault();
      this.dismiss();
      this.input.form?.requestSubmit(document.getElementById("send-btn"));
      return true;
    }
    return false;
  }

  dismiss() {
    this.cancelLookup();
    this.context = null;
    this.result = null;
    this.items = [];
    this.snapshot = this.read();
    this.view.close();
  }

  destroy() {
    this.dismiss();
    this.controller.abort();
    this.observer.disconnect();
    cancelAnimationFrame(this.frame);
    this.hook.removeHandleEvent(this.resultsRef);
    this.view.layer.replaceChildren();
  }
}

export const DirectoryComplete = {
  mounted() {
    this.completer = new Completer(this, this.el.querySelector("input"), {
      kind: this.el.dataset.kind, event: this.el.dataset.event
    });
  },
  updated() { this.completer.refresh(); },
  disconnected() { this.completer.dismiss(); },
  destroyed() { this.completer.destroy(); }
};
