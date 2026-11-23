// Client-side slash command, argument, workspace file (@), inline path, and
// directory auto-completion with pixel-aligned inline ghost hints.
// Uses textContent exclusively (never innerHTML) to satisfy strict CSP and XSS safety.

function parseMeta(raw) {
  if (!raw) return { commands: [], thinking_levels: [], attention_args: [], archive_args: [], models: [] };
  try {
    const parsed = JSON.parse(raw);
    return {
      commands: Array.isArray(parsed.commands) ? parsed.commands : [],
      thinking_levels: Array.isArray(parsed.thinking_levels) ? parsed.thinking_levels : [],
      attention_args: Array.isArray(parsed.attention_args) ? parsed.attention_args : [],
      archive_args: Array.isArray(parsed.archive_args) ? parsed.archive_args : [],
      models: Array.isArray(parsed.models) ? parsed.models : []
    };
  } catch (_err) {
    return { commands: [], thinking_levels: [], attention_args: [], archive_args: [], models: [] };
  }
}

function ghostSuffixFor(typed, completion) {
  if (!typed || !completion) return "";
  if (completion.length <= typed.length) return "";
  if (completion.toLowerCase().startsWith(typed.toLowerCase())) {
    return completion.slice(typed.length);
  }
  return "";
}

function tokenAtCursor(value, cursor) {
  let start = cursor;
  while (start > 0 && !/\s/.test(value[start - 1])) start -= 1;
  let end = cursor;
  while (end < value.length && !/\s/.test(value[end])) end += 1;
  return {
    start,
    end,
    cursor,
    prefix: value.slice(start, cursor),
    full: value.slice(start, end)
  };
}

function isPathLikePrefix(prefix) {
  if (!prefix) return false;
  return (
    prefix.startsWith("./") ||
    prefix.startsWith("../") ||
    prefix.startsWith("~/") ||
    prefix === "~" ||
    prefix.startsWith("/") ||
    prefix.includes("/")
  );
}

function isShellLine(value) {
  const trimmed = value.trimStart();
  return trimmed.startsWith("!") || trimmed.startsWith("/steer !") || trimmed.startsWith("/follow-up !");
}

function renderPopupList(popup, items, selectedIdx, onSelect) {
  popup.textContent = "";
  if (!items.length) {
    popup.hidden = true;
    return;
  }

  items.forEach((item, idx) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = idx === selectedIdx ? "completion-item is-selected" : "completion-item";
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", idx === selectedIdx ? "true" : "false");

    const label = document.createElement("span");
    label.className = "completion-item-label mono";
    label.textContent = item.label || item.value;
    row.appendChild(label);

    if (item.kind) {
      const badge = document.createElement("span");
      badge.className = "completion-item-kind mono";
      badge.textContent = item.kind;
      row.appendChild(badge);
    }

    if (item.description) {
      const desc = document.createElement("span");
      desc.className = "completion-item-desc muted";
      desc.textContent = item.description;
      row.appendChild(desc);
    }

    row.addEventListener("mousedown", event => {
      // Prevent textarea/input blur before click commits.
      event.preventDefault();
    });
    row.addEventListener("click", event => {
      event.preventDefault();
      onSelect(item);
    });

    popup.appendChild(row);
  });

  popup.hidden = false;
  const activeEl = popup.children[selectedIdx];
  if (activeEl && typeof activeEl.scrollIntoView === "function") {
    activeEl.scrollIntoView({ block: "nearest" });
  }
}

export class ComposerCompleter {
  constructor(hook, textarea) {
    this.hook = hook;
    this.el = textarea;
    this.popup = document.getElementById("composer-completions");
    this.ghost = document.getElementById("composer-ghost");
    this.ghostMirror = this.ghost?.querySelector(".ghost-mirror") || null;
    this.ghostSuffix = this.ghost?.querySelector(".ghost-suffix") || null;
    this.meta = parseMeta(textarea.dataset.completionMeta);

    this.items = [];
    this.selected = 0;
    this.context = null;
    this.ghostHint = "";
    this.lookupSeq = 0;
    this.pendingLookupId = null;
    this.debounceTimer = null;

    this.onScroll = () => this.syncGhostScroll();
    this.onSelectionChange = () => this.update(false);
    this.onBlur = () => {
      // Small delay allows mousedown/click on popup items to execute.
      window.setTimeout(() => {
        if (document.activeElement !== this.el) this.dismiss();
      }, 120);
    };

    this.el.addEventListener("scroll", this.onScroll);
    this.el.addEventListener("click", this.onSelectionChange);
    this.el.addEventListener("keyup", this.onKeyupSelection);
    this.el.addEventListener("blur", this.onBlur);

    this.hook.handleEvent("completion_results", payload => {
      if (!payload || payload.target_id !== this.el.id) return;
      if (payload.lookup_id !== this.pendingLookupId) return;
      if (!this.context || this.context.asyncKind !== payload.kind) return;
      const list = Array.isArray(payload.items) ? payload.items : [];
      this.items = list.map(entry => ({
        value: entry.value,
        label: entry.label || entry.value,
        kind: entry.kind || "",
        description: entry.description || ""
      }));
      this.selected = 0;
      this.render();
    });
  }

  onKeyupSelection = event => {
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
      this.update(false);
    }
  };

  refreshMeta() {
    this.meta = parseMeta(this.el.dataset.completionMeta);
  }

  isOpen() {
    return this.items.length > 0 && this.popup && !this.popup.hidden;
  }

  hasGhostSuffix() {
    return Boolean(this.ghostSuffix && this.ghostSuffix.textContent !== "");
  }

  dismiss() {
    if (this.debounceTimer) {
      window.clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.pendingLookupId = null;
    this.items = [];
    this.selected = 0;
    this.context = null;
    this.ghostHint = "";
    if (this.popup) {
      this.popup.textContent = "";
      this.popup.hidden = true;
    }
    this.clearGhost();
  }

  clearGhost() {
    if (this.ghostMirror) this.ghostMirror.textContent = "";
    if (this.ghostSuffix) this.ghostSuffix.textContent = "";
  }

  syncGhostScroll() {
    if (this.ghost) {
      this.ghost.scrollTop = this.el.scrollTop;
    }
  }

  analyzeContext(explicitTab) {
    const value = this.el.value;
    const cursor = this.el.selectionStart ?? value.length;
    const selEnd = this.el.selectionEnd ?? cursor;
    if (cursor !== selEnd) return null;

    const before = value.slice(0, cursor);

    // 1. Slash command name or argument on single-line leading "/"
    if (value.startsWith("/") && !value.startsWith("//") && !before.includes("\n")) {
      const spaceIdx = before.search(/\s/);
      if (spaceIdx === -1) {
        return {
          mode: "command",
          replaceStart: 0,
          replaceEnd: value.search(/\s/) === -1 ? value.length : value.search(/\s/),
          prefix: before
        };
      }

      const cmdName = before.slice(0, spaceIdx).toLowerCase();
      const cmdSpec = this.meta.commands.find(c => c.name === cmdName);
      if (cmdSpec) {
        const afterCmd = before.slice(spaceIdx + 1);
        if (cmdName === "/cwd") {
          const argStart = spaceIdx + 1 + (afterCmd.length - afterCmd.trimStart().length);
          const argPrefix = before.slice(argStart);
          return {
            mode: "async",
            asyncKind: "directory",
            cmdSpec,
            replaceStart: argStart,
            replaceEnd: cursor,
            prefix: argPrefix
          };
        }

        if (["/thinking", "/model", "/attention", "/archive", "/fork"].includes(cmdName)) {
          const trimmedStartLen = afterCmd.length - afterCmd.trimStart().length;
          const argStart = spaceIdx + 1 + trimmedStartLen;
          const argPrefix = before.slice(argStart);
          if (!argPrefix.includes(" ")) {
            return {
              mode: "command_arg",
              cmdName,
              cmdSpec,
              replaceStart: argStart,
              replaceEnd: cursor,
              prefix: argPrefix
            };
          }
        }

        // For commands taking arbitrary text/args (/steer, /follow-up, etc.), allow @ or path completion below.
      }
    }

    // 2. Token-level @workspace_file or inline path/directory completion
    const tok = tokenAtCursor(value, cursor);
    if (tok.prefix.startsWith("@")) {
      return {
        mode: "async",
        asyncKind: "workspace_file",
        replaceStart: tok.start,
        replaceEnd: tok.end,
        prefix: tok.prefix.slice(1),
        insertPrefix: "@"
      };
    }

    if (tok.prefix && (isPathLikePrefix(tok.prefix) || explicitTab)) {
      if (tok.start === 0 && tok.prefix.startsWith("/")) {
        return null;
      }
      return {
        mode: "async",
        asyncKind: "path",
        shell: isShellLine(value),
        replaceStart: tok.start,
        replaceEnd: tok.end,
        prefix: tok.prefix
      };
    }

    return null;
  }

  update(explicitTab = false) {
    const ctx = this.analyzeContext(explicitTab);
    if (!ctx) {
      this.dismiss();
      return;
    }

    this.context = ctx;
    this.ghostHint = "";

    if (ctx.mode === "command") {
      this.pendingLookupId = null;
      const q = ctx.prefix.toLowerCase();
      const qNoSlash = q.slice(1);
      const prefixMatches = [];
      const containsMatches = [];
      for (const cmd of this.meta.commands) {
        if (q === "/" || cmd.name.startsWith(q)) {
          prefixMatches.push(cmd);
        } else if (qNoSlash && cmd.name.includes(qNoSlash)) {
          containsMatches.push(cmd);
        }
      }
      this.items = [...prefixMatches, ...containsMatches].map(cmd => ({
        value: cmd.name,
        label: cmd.usage || cmd.name,
        description: cmd.description || "",
        takesArg: Boolean(cmd.takes_arg),
        argHint: cmd.arg_hint || ""
      }));
      this.selected = 0;
      this.render();
      return;
    }

    if (ctx.mode === "command_arg") {
      this.pendingLookupId = null;
      this.items = this.staticArgChoices(ctx.cmdName, ctx.prefix);
      this.selected = 0;
      this.ghostHint = ctx.prefix === "" && ctx.cmdSpec?.arg_hint ? ctx.cmdSpec.arg_hint : "";
      this.render();
      return;
    }

    if (ctx.mode === "async") {
      if (ctx.asyncKind === "directory" && ctx.prefix === "") {
        this.ghostHint = "<directory>";
      }
      this.scheduleAsyncLookup(ctx, explicitTab ? 0 : 60);
    }
  }

  staticArgChoices(cmdName, prefix) {
    const q = prefix.toLowerCase();
    if (cmdName === "/thinking") {
      return this.meta.thinking_levels
        .filter(level => level.startsWith(q))
        .map(level => ({ value: level, label: level, description: "Reasoning effort" }));
    }
    if (cmdName === "/attention") {
      return this.meta.attention_args
        .filter(val => val.startsWith(q))
        .map(val => ({
          value: val,
          label: val,
          description: val === "on" ? "Mark for attention" : "Mark as read"
        }));
    }
    if (cmdName === "/archive") {
      return this.meta.archive_args
        .filter(val => val.startsWith(q))
        .map(val => ({
          value: val,
          label: val,
          description: val === "force" ? "Stop work and archive" : "Restore from archive"
        }));
    }
    if (cmdName === "/fork") {
      return "cancel".startsWith(q)
        ? [{ value: "cancel", label: "cancel", description: "Cancel active fork-edit" }]
        : [];
    }
    if (cmdName === "/model") {
      const pref = [];
      const contains = [];
      for (const m of this.meta.models) {
        const idLow = (m.id || "").toLowerCase();
        const labelLow = (m.label || "").toLowerCase();
        if (!q || idLow.startsWith(q)) {
          pref.push(m);
        } else if (idLow.includes(q) || labelLow.includes(q)) {
          contains.push(m);
        }
      }
      return [...pref, ...contains].slice(0, 30).map(m => ({
        value: m.id,
        label: m.id,
        description: m.label || m.provider || ""
      }));
    }
    return [];
  }

  scheduleAsyncLookup(ctx, delayMs) {
    if (this.debounceTimer) {
      window.clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    const run = () => {
      this.debounceTimer = null;
      this.lookupSeq += 1;
      const lookupId = this.lookupSeq;
      this.pendingLookupId = lookupId;
      this.hook.pushEvent("complete_path", {
        lookup_id: lookupId,
        target_id: this.el.id,
        kind: ctx.asyncKind,
        prefix: ctx.prefix,
        shell: Boolean(ctx.shell)
      });
    };

    if (delayMs === 0) {
      run();
    } else {
      this.debounceTimer = window.setTimeout(run, delayMs);
    }
  }

  render() {
    if (this.popup) {
      renderPopupList(this.popup, this.items, this.selected, item => this.accept(item));
    }
    this.renderGhost();
  }

  renderGhost() {
    if (!this.ghostMirror || !this.ghostSuffix) return;
    const value = this.el.value;
    const cursor = this.el.selectionStart ?? value.length;
    const selEnd = this.el.selectionEnd ?? cursor;

    // Only render inline ghost suffix when caret sits cleanly at the very end.
    if (cursor !== value.length || cursor !== selEnd || !this.context) {
      this.clearGhost();
      return;
    }

    const active = this.items[this.selected];
    let suffix = "";

    if (active) {
      if (this.context.mode === "command") {
        suffix = ghostSuffixFor(this.context.prefix, active.value);
        if (!suffix && active.value === this.context.prefix.toLowerCase() && active.argHint) {
          suffix = ` ${active.argHint}`;
        } else if (suffix && active.argHint) {
          suffix = `${suffix} ${active.argHint}`;
        }
      } else if (this.context.mode === "command_arg") {
        suffix = ghostSuffixFor(this.context.prefix, active.value);
        if (!suffix && this.context.prefix === "") {
          suffix = active.value;
        }
      } else if (this.context.mode === "async") {
        const typed = this.context.insertPrefix
          ? this.context.prefix
          : this.context.prefix;
        suffix = ghostSuffixFor(typed, active.value);
        if (!suffix && typed === "" && this.context.asyncKind === "directory") {
          suffix = active.value;
        }
      }
    } else if (this.ghostHint) {
      suffix = this.ghostHint;
    }

    if (!suffix) {
      this.clearGhost();
      return;
    }

    this.ghostMirror.textContent = value;
    this.ghostSuffix.textContent = suffix;
    this.syncGhostScroll();
  }

  moveSelection(delta) {
    if (!this.items.length) return;
    const len = this.items.length;
    this.selected = (this.selected + delta + len) % len;
    this.render();
  }

  accept(item = this.items[this.selected]) {
    if (!item || !this.context) return false;
    const ctx = this.context;
    const value = this.el.value;

    let inserted = item.value;
    let shouldChain = false;

    if (ctx.mode === "command") {
      if (item.takesArg) {
        inserted = `${item.value} `;
        shouldChain = true;
      }
    } else if (ctx.mode === "async") {
      if (ctx.insertPrefix === "@") {
        // Strip leading '@' when inserting workspace file path so the model receives the clean path.
        inserted = item.value;
        shouldChain = item.value.endsWith("/");
      } else {
        inserted = item.value;
        shouldChain = item.value.endsWith("/");
      }
    }

    const nextValue = value.slice(0, ctx.replaceStart) + inserted + value.slice(ctx.replaceEnd);
    const nextCursor = ctx.replaceStart + inserted.length;

    this.el.value = nextValue;
    this.el.focus({ preventScroll: true });
    this.el.setSelectionRange(nextCursor, nextCursor);
    this.el.dispatchEvent(new Event("input", { bubbles: true }));

    if (shouldChain) {
      this.update(true);
    } else {
      this.dismiss();
    }
    return true;
  }

  handleKeydown(event) {
    if (event.isComposing) return false;

    const popupOpen = this.isOpen();

    if (event.key === "Escape") {
      if (popupOpen || this.hasGhostSuffix()) {
        event.preventDefault();
        this.dismiss();
        return true;
      }
      return false;
    }

    if (popupOpen && event.key === "ArrowDown") {
      event.preventDefault();
      this.moveSelection(1);
      return true;
    }

    if (popupOpen && event.key === "ArrowUp") {
      event.preventDefault();
      this.moveSelection(-1);
      return true;
    }

    if (event.key === "Tab") {
      if (popupOpen) {
        event.preventDefault();
        this.accept();
        return true;
      }
      const ctx = this.analyzeContext(true);
      if (ctx) {
        event.preventDefault();
        this.update(true);
        return true;
      }
      return false;
    }

    if (
      event.key === "ArrowRight" &&
      !event.shiftKey &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      this.el.selectionStart === this.el.value.length &&
      this.el.selectionEnd === this.el.value.length &&
      popupOpen &&
      this.hasGhostSuffix()
    ) {
      event.preventDefault();
      this.accept();
      return true;
    }

    // Plain Enter on a single-line leading "/" slash command:
    // - If popup is open and text is an incomplete command prefix (e.g. "/tr"),
    //   complete/execute the highlighted command smoothly.
    // - If text is already a complete slash command (e.g. "/tree" or "/thinking high"),
    //   submit the form!
    if (
      event.key === "Enter" &&
      !event.shiftKey &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      const value = this.el.value;
      const singleLineSlash =
        value.startsWith("/") && !value.startsWith("//") && !value.includes("\n");

      if (singleLineSlash) {
        event.preventDefault();
        const trimmed = value.trim();
        const exactCmd = this.meta.commands.find(c => c.name === trimmed.toLowerCase());

        if (popupOpen && this.context?.mode === "command" && !exactCmd) {
          const chosen = this.items[this.selected];
          if (chosen) {
            if (chosen.takesArg) {
              this.accept(chosen);
              return true;
            }
            this.el.value = chosen.value;
            this.el.dispatchEvent(new Event("input", { bubbles: true }));
            this.dismiss();
            this.el.form?.requestSubmit(document.getElementById("send-btn"));
            return true;
          }
        }

        if (popupOpen && this.context?.mode === "command_arg") {
          const chosen = this.items[this.selected];
          if (chosen && chosen.value.toLowerCase() !== this.context.prefix.toLowerCase()) {
            this.accept(chosen);
            return true;
          }
        }

        this.dismiss();
        this.el.form?.requestSubmit(document.getElementById("send-btn"));
        return true;
      }
    }

    return false;
  }

  destroy() {
    this.dismiss();
    this.el.removeEventListener("scroll", this.onScroll);
    this.el.removeEventListener("click", this.onSelectionChange);
    this.el.removeEventListener("keyup", this.onKeyupSelection);
    this.el.removeEventListener("blur", this.onBlur);
  }
}

export const DirectoryComplete = {
  mounted() {
    this.input = this.el.querySelector("input");
    this.popup = this.el.querySelector(".dir-completions");
    this.ghostMirror = this.el.querySelector(".dir-ghost .ghost-mirror");
    this.ghostSuffix = this.el.querySelector(".dir-ghost .ghost-suffix");
    this.eventName = this.el.dataset.event || "complete_directory";
    this.kind = this.el.dataset.kind || "directory";
    this.targetId = this.el.dataset.targetId || this.input?.id || "";

    this.items = [];
    this.selected = 0;
    this.lookupSeq = 0;
    this.pendingLookupId = null;
    this.debounceTimer = null;

    if (!this.input) return;

    this.onInput = () => {
      this.renderGhost();
      this.scheduleLookup(60);
    };

    this.onKeydown = event => {
      if (event.isComposing) return;
      const popupOpen = this.items.length > 0 && this.popup && !this.popup.hidden;

      if (event.key === "Escape" && (popupOpen || this.ghostSuffix?.textContent)) {
        event.preventDefault();
        this.dismiss();
        return;
      }

      if (popupOpen && event.key === "ArrowDown") {
        event.preventDefault();
        this.selected = (this.selected + 1) % this.items.length;
        this.render();
        return;
      }

      if (popupOpen && event.key === "ArrowUp") {
        event.preventDefault();
        this.selected = (this.selected - 1 + this.items.length) % this.items.length;
        this.render();
        return;
      }

      if (event.key === "Tab") {
        event.preventDefault();
        if (popupOpen) {
          this.accept(this.items[this.selected]);
        } else {
          this.scheduleLookup(0);
        }
        return;
      }

      if (
        event.key === "ArrowRight" &&
        !event.shiftKey &&
        !event.metaKey &&
        !event.ctrlKey &&
        this.input.selectionStart === this.input.value.length &&
        this.input.selectionEnd === this.input.value.length &&
        popupOpen &&
        this.ghostSuffix?.textContent
      ) {
        event.preventDefault();
        this.accept(this.items[this.selected]);
      }
    };

    this.onBlur = () => {
      window.setTimeout(() => {
        if (document.activeElement !== this.input) this.dismiss();
      }, 120);
    };

    this.input.addEventListener("input", this.onInput);
    this.input.addEventListener("keydown", this.onKeydown);
    this.input.addEventListener("blur", this.onBlur);

    this.handleEvent("completion_results", payload => {
      if (!payload || payload.target_id !== this.targetId) return;
      if (payload.lookup_id !== this.pendingLookupId) return;
      this.items = Array.isArray(payload.items) ? payload.items : [];
      this.selected = 0;
      this.render();
    });
  },

  scheduleLookup(delayMs) {
    if (this.debounceTimer) {
      window.clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    const run = () => {
      this.debounceTimer = null;
      this.lookupSeq += 1;
      const lookupId = this.lookupSeq;
      this.pendingLookupId = lookupId;
      this.pushEvent(this.eventName, {
        lookup_id: lookupId,
        target_id: this.targetId,
        kind: this.kind,
        prefix: this.input.value
      });
    };
    if (delayMs === 0) run();
    else this.debounceTimer = window.setTimeout(run, delayMs);
  },

  render() {
    if (this.popup) {
      renderPopupList(this.popup, this.items, this.selected, item => this.accept(item));
    }
    this.renderGhost();
  },

  renderGhost() {
    if (!this.ghostMirror || !this.ghostSuffix || !this.input) return;
    const value = this.input.value;
    const cursor = this.input.selectionStart ?? value.length;
    const selEnd = this.input.selectionEnd ?? cursor;
    const active = this.items[this.selected];
    if (!active || cursor !== value.length || cursor !== selEnd) {
      this.ghostMirror.textContent = "";
      this.ghostSuffix.textContent = "";
      return;
    }
    const suffix = ghostSuffixFor(value, active.value);
    if (!suffix) {
      this.ghostMirror.textContent = "";
      this.ghostSuffix.textContent = "";
      return;
    }
    this.ghostMirror.textContent = value;
    this.ghostSuffix.textContent = suffix;
  },

  accept(item) {
    if (!item || !this.input) return;
    this.input.value = item.value;
    this.input.focus({ preventScroll: true });
    this.input.setSelectionRange(item.value.length, item.value.length);
    this.input.dispatchEvent(new Event("input", { bubbles: true }));
    if (item.value.endsWith("/")) {
      this.scheduleLookup(0);
    } else {
      this.dismiss();
    }
  },

  dismiss() {
    if (this.debounceTimer) {
      window.clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.pendingLookupId = null;
    this.items = [];
    this.selected = 0;
    if (this.popup) {
      this.popup.textContent = "";
      this.popup.hidden = true;
    }
    if (this.ghostMirror) this.ghostMirror.textContent = "";
    if (this.ghostSuffix) this.ghostSuffix.textContent = "";
  },

  destroyed() {
    this.dismiss();
    if (this.input) {
      this.input.removeEventListener("input", this.onInput);
      this.input.removeEventListener("keydown", this.onKeydown);
      this.input.removeEventListener("blur", this.onBlur);
    }
  }
};
