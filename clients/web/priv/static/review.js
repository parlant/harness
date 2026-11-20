const asset = (name) => new URL(`./monaco/${name}`, import.meta.url);
let monacoPromise;

function loadMonaco() {
  if (!monacoPromise) {
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = asset("editor.css");
    const styled = new Promise((resolve, reject) => {
      css.onload = resolve;
      css.onerror = reject;
    });
    document.head.append(css);
    globalThis.MonacoEnvironment = {
      getWorker(_module, label) {
        const worker = {json: "json", css: "css", less: "css", scss: "css", html: "html",
          handlebars: "html", razor: "html", typescript: "ts", javascript: "ts"}[label] || "editor";
        return new Worker(asset(`${worker}.worker.js`), {type: "module"});
      }
    };
    monacoPromise = Promise.all([styled, import(asset("editor.js"))]).then(([, api]) => api);
  }
  return monacoPromise;
}

const lineColumn = (text, offset) => {
  const lines = text.slice(0, offset).split("\n");
  return [lines.length, lines.at(-1).length + 1];
};
const normalize = (text) => text.replace(/^\uFEFF/, "").replace(/\r\n?|\n/g, "\n");
const POLL_MS = 1500;

export const ReviewEditor = {
  mounted() {
    const find = (attr) => this.el.querySelector(`[data-review-${attr}]`);
    this.fields = {
      path: find("path"), status: find("status"), text: find("text"), monaco: find("monaco"),
      media: find("media"), comment: find("comment"), range: find("range")
    };
    this.buttons = Object.fromEntries([...this.el.querySelectorAll("[data-review]")]
      .map((button) => [button.dataset.review, button]));
    this.fields.comment.addEventListener("submit", (event) => this.submitComment(event));
    this.fields.text.addEventListener("input", () => this.changed());
    this.el.addEventListener("click", (event) => {
      const action = event.target.closest("[data-review]")?.dataset.review;
      if (action === "save") this.save();
      else if (action === "select") this.captureSelection();
      else if (action === "reload") this.switchView(this.view, true);
      else if (["working", "head", "diff", "preview"].includes(action)) this.switchView(action);
    });
    this.beforeUnload = (event) => {
      if (this.dirty) event.preventDefault();
    };
    window.addEventListener("beforeunload", this.beforeUnload);
    // A working-tree write must not be retried automatically on reconnect.
    this.onNavigate = (event) => {
      if (this.dirty && (event.target.closest("[data-phx-link]")) &&
          !window.confirm("Leave this review and discard unsaved edits?")) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    };
    window.addEventListener("click", this.onNavigate, true);
    this.files = {};
    this.generation = 0;
    this.path = this.el.dataset.path;
    this.url = this.el.dataset.url;
    this.switchView(this.el.dataset.deleted === "true" ? "head" : "working", true);
    loadMonaco().then((api) => {
      if (this.dead) return;
      this.api = api;
      // Don't replace a textarea the user has already started editing in.
      if (!this.dirty && !this.anchor && this.current) this.display(this.current);
    }).catch(() => { /* Text review remains available without built assets. */ });
  },

  updated() {
    if (this.path !== this.el.dataset.path) {
      if (this.dirty || this.fields.comment.elements.note.value.trim()) {
        // LiveView tracks which file is authoritative for mutations. If the
        // browser retains the old draft, it must first re-select that file.
        if (!window.confirm("Discard the unsaved file or comment draft and open the selected file?")) {
          this.pushEvent("review_open", {path: this.path, deleted: String(this.view === "head" && !this.files.working)});
          this.updateControls();
          return;
        }
      }
      this.pending = false;
      this.path = this.el.dataset.path;
      this.url = this.el.dataset.url;
      this.files = {};
      this.fields.comment.reset();
      this.switchView(this.el.dataset.deleted === "true" ? "head" : "working", true);
    }
    this.updateControls();
  },

  disconnected() {
    if (!this.pending) return;
    this.pending = false;
    this.message("Connection lost. Check the file or session before retrying.");
    this.updateControls();
  },

  destroyed() {
    this.dead = true;
    clearTimeout(this.timer);
    this.fetchController?.abort();
    this.disposeEditor();
    window.removeEventListener("beforeunload", this.beforeUnload);
    window.removeEventListener("click", this.onNavigate, true);
  },

  message(text) { this.fields.status.textContent = text; },

  async switchView(view, discard = false) {
    if (this.pending || (this.dirty && !discard)) {
      this.message("Save or discard your edits before switching views.");
      return;
    }
    this.fetchController?.abort();
    this.view = view;
    this.generation++;
    this.dirty = false;
    this.conflict = false;
    this.anchor = null;
    this.current = null;
    this.files = {};
    this.fields.path.textContent = this.path;
    this.disposeEditor();
    this.hideDocument();
    this.message("Loading file…");
    this.updateControls();
    await this.poll(this.generation);
  },

  async fetchFile(source, signal) {
    const url = new URL(this.url, location.href);
    url.searchParams.set("source", source);
    const previous = this.files[source];
    const headers = previous ? {"If-None-Match": `"${previous.revision}"`} : {};
    const response = await fetch(url, {headers, signal, credentials: "same-origin", cache: "no-store"});
    if (response.status === 304) return previous;
    if (response.redirected) throw new Error("Sign in again to continue reviewing files.");
    const file = await response.json();
    return file;
  },

  async poll(generation) {
    clearTimeout(this.timer);
    const controller = new AbortController();
    this.fetchController = controller;
    try {
      if (this.pending || document.hidden && this.current) return;
      const mode = this.view;
      const sources = mode === "diff" ? ["head", "working"] : [mode === "head" ? "head" : "working"];
      const files = await Promise.all(sources.map((source) => this.fetchFile(source, controller.signal)));
      if (generation !== this.generation || this.dead || this.pending) return;
      const [first, second] = files;
      const current = second || first;
      const key = JSON.stringify(files.map((file) => file.revision || file.error));
      const changed = this.currentKey !== key || !this.current;
      if (this.dirty) {
        const conflict = current.revision !== this.base?.revision;
        if (conflict !== this.conflict) {
          this.conflict = conflict;
          this.message(conflict ? "File changed on disk. Your draft was kept; discard it to reload." : "Unsaved edits.");
          this.updateControls();
        }
        return;
      }
      if (!changed) return;
      this.currentKey = key;
      this.current = current;
      sources.forEach((source, i) => { this.files[source] = files[i]; });
      this.anchor = null;
      this.display(current);
    } catch (error) {
      if (error.name !== "AbortError" && generation === this.generation && !this.dead) {
        this.message(error.message || "Could not load file. Retrying…");
      }
    } finally {
      if (generation === this.generation && !this.dead) {
        this.timer = setTimeout(() => this.poll(generation), POLL_MS);
      }
    }
  },

  disposeEditor() {
    this.editor?.dispose();
    this.editor = null;
    this.highlight = null;
    this.models?.forEach((model) => model.dispose());
    this.models = [];
  },

  hideDocument() {
    this.fields.text.hidden = true;
    this.fields.monaco.hidden = true;
    this.fields.media.hidden = true;
    this.fields.media.replaceChildren();
  },

  display(file) {
    const openDiff = this.view === "diff";
    const previousView = !openDiff && this.editor?.saveViewState();
    const hadFocus = !openDiff && this.editor?.hasTextFocus();
    this.disposeEditor();
    this.hideDocument();
    this.base = null;
    this.message("");
    // Missing HEAD for new files; missing worktree version for deletions.
    if (openDiff) {
      const head = this.files.head;
      if ((head.kind === "text" && (file.kind === "text" || file.code === "missing")) ||
          (head.code === "missing" && file.kind === "text")) this.displayDiff(file);
      else this.message(head.code === "unavailable" ? head.error :
        file.code === "unavailable" ? file.error : "Diffs are available for text files only.");
    } else if (file.error) {
      this.message(file.error);
    } else if (this.view === "preview" || file.kind === "media") {
      if (file.preview) this.preview(file);
      else this.message("No preview is available for this file.");
    } else if (file.kind === "text") {
      this.base = file;
      if (this.api) {
        this.fields.monaco.hidden = false;
        const model = this.model(file.text);
        this.editor = this.api.editor.create(this.fields.monaco, {
          model, readOnly: !this.editable(), automaticLayout: true, minimap: {enabled: false},
          theme: this.theme(), ariaLabel: `File text: ${this.path}`, links: false
        });
        if (previousView) this.editor.restoreViewState(previousView);
        if (hadFocus) this.editor.focus();
        this.highlight = this.editor.createDecorationsCollection();
        this.editor.onDidChangeModelContent(() => this.changed());
      } else {
        const text = this.fields.text;
        const {selectionStart, selectionEnd, scrollTop, scrollLeft} = text;
        text.value = normalize(file.text);
        text.readOnly = !this.editable();
        text.hidden = false;
        text.setSelectionRange(selectionStart, selectionEnd);
        text.scrollTop = scrollTop;
        text.scrollLeft = scrollLeft;
      }
    }
    this.updateControls();
  },

  model(text, name = this.path) {
    const model = this.api.editor.createModel(text, undefined, this.api.Uri.from({scheme: "review", path: `/${name}`}));
    this.models.push(model);
    return model;
  },

  theme() { return matchMedia("(prefers-color-scheme: dark)").matches ? "vs-dark" : "vs"; },

  displayDiff(file) {
    const head = this.files.head;
    const original = head?.text || "";
    const modified = file.text || "";
    if (!this.api) {
      this.message("The diff viewer needs Monaco. Working file and HEAD can still be viewed separately.");
      return;
    }
    this.fields.monaco.hidden = false;
    this.editor = this.api.editor.createDiffEditor(this.fields.monaco, {
      readOnly: true, originalEditable: false, automaticLayout: true,
      minimap: {enabled: false}, theme: this.theme(), links: false
    });
    this.editor.setModel({original: this.model(original, `HEAD/${this.path}`), modified: this.model(modified)});
    this.message("Compare HEAD → working file. To comment, select text in Working file or HEAD.");
  },

  preview(file) {
    const url = new URL(this.url, location.href);
    url.searchParams.set("preview", "1");
    url.searchParams.set("rev", file.revision);
    const tag = {html: "iframe", image: "img", audio: "audio", video: "video"}[file.preview];
    if (!tag) return;
    const media = document.createElement(tag);
    if (tag === "iframe") {
      media.title = "Sandboxed HTML preview";
      media.setAttribute("sandbox", "");
    } else if (tag === "img") media.alt = this.path;
    else media.controls = true;
    media.src = url.href;
    this.fields.media.replaceChildren(media);
    this.fields.media.hidden = false;
  },

  editable() { return this.view === "working" && this.el.dataset.readonly !== "true"; },

  text() {
    if (this.editor) return this.editor.getModel().getValue(undefined, true);
    const raw = this.base.text;
    const eol = raw.includes("\r\n") ? "\r\n" : raw.includes("\r") && !raw.includes("\n") ? "\r" : "\n";
    return (raw.startsWith("\uFEFF") ? "\uFEFF" : "") + this.fields.text.value.replaceAll("\n", eol);
  },

  changed() {
    if (!this.base) return;
    this.dirty = normalize(this.text()) !== normalize(this.base.text);
    if (this.dirty) {
      this.anchor = null;
      this.highlight?.clear();
    }
    if (!this.dirty && this.conflict) return this.switchView(this.view, true);
    this.message(this.conflict ? "File changed on disk. Your draft was kept; discard it to reload." : this.dirty ? "Unsaved edits." : "");
    this.updateControls();
  },

  updateControls() {
    const matched = this.path === this.el.dataset.path;
    if (this.base && !this.pending) {
      if (this.editor) this.editor.updateOptions({readOnly: !this.editable()});
      else this.fields.text.readOnly = !this.editable();
    }
    this.buttons.save.disabled = !matched || !this.editable() || !this.dirty || this.conflict || this.pending;
    this.buttons.reload.hidden = !this.dirty;
    this.buttons.head.hidden = this.buttons.diff.hidden = this.el.dataset.git === "false";
    this.buttons.preview.hidden = !(this.files.working?.preview || this.current?.preview);
    this.fields.comment.hidden = !this.base || this.el.dataset.readonly === "true";
    this.buttons.select.disabled = this.dirty || this.pending;
    this.fields.range.textContent = this.anchor ? `Lines ${this.anchor.range[0]}–${this.anchor.range[2]}` : "Select a passage in the saved file.";
    for (const button of this.fields.comment.querySelectorAll('[type="submit"]')) {
      button.disabled = !matched || !this.anchor || this.pending;
    }
    for (const tab of ["working", "head", "diff", "preview"]) {
      this.buttons[tab].setAttribute("aria-pressed", String(this.view === tab));
    }
  },

  captureSelection() {
    if (!this.base || this.dirty) return;
    let range;
    if (this.editor) {
      const r = this.editor.getSelection();
      if (r && !r.isEmpty()) range = [r.startLineNumber, r.startColumn, r.endLineNumber, r.endColumn];
    } else {
      const {value, selectionStart, selectionEnd} = this.fields.text;
      if (selectionStart !== selectionEnd) range = [...lineColumn(value, selectionStart), ...lineColumn(value, selectionEnd)];
    }
    if (!range) {
      this.message("Select text in the editor first.");
      return;
    }
    this.anchor = {range, revision: this.base.revision, source: this.view, request_id: crypto.randomUUID()};
    if (this.editor) {
      this.highlight.set([{
        range: new this.api.Range(...range), options: {className: "review-highlight"}
      }]);
    }
    this.updateControls();
    this.fields.comment.elements.note.focus();
  },

  send(event, data, onSuccess) {
    const path = this.path;
    const generation = this.generation;
    this.pending = true;
    this.updateControls();
    this.pushEvent(event, {...data, path}).then((reply) => {
      if (this.dead || generation !== this.generation || this.path !== path) return;
      this.pending = false;
      if (reply?.ok) onSuccess(reply.result);
      else {
        if (reply?.code === "file_changed" && this.dirty) this.conflict = true;
        this.message(reply?.error || "The request failed. Check the file or session before retrying.");
      }
      this.updateControls();
    }, () => {
      if (generation === this.generation) this.disconnected();
    });
  },

  save() {
    if (this.buttons.save.disabled) return;
    const text = this.text();
    if (new TextEncoder().encode(text).length > 512 * 1024) {
      this.message("File exceeds the 512 KiB edit limit.");
      return;
    }
    this.send("review_save", {revision: this.base.revision, text}, (revision) => {
      this.base = {...this.base, text, revision};
      this.files.working = this.base;
      this.current = this.base;
      this.currentKey = JSON.stringify([revision]);
      this.dirty = normalize(this.text()) !== normalize(text);
      this.message(this.dirty ? "File saved; there are newer unsaved edits." : "File saved.");
    });
  },

  submitComment(event) {
    event.preventDefault();
    if (!this.anchor || this.dirty || this.pending || this.path !== this.el.dataset.path) return;
    const action = event.submitter?.value || "save";
    this.send("review_comment", {...this.anchor, note: this.fields.comment.elements.note.value, action}, () => {
      this.fields.comment.reset();
      this.anchor = null;
      this.highlight?.clear();
      this.message(action === "ask" ? "Comment sent to the agent." : "Comment saved to the session.");
    });
  }
};
