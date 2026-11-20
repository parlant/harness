// Pane width is local to this browser tab, not part of a session's history.
export const PaneSplitter = {
  mounted() {
    const el = this.el, pane = el.parentElement, key = `hweb:width:${pane.id}`;
    const resize = width => {
      this.width = Math.max(200, Math.min(440, Math.round(width)));
      pane.style.setProperty("--sidebar-width", `${this.width}px`);
      el.setAttribute("aria-valuenow", this.width);
    };
    const save = () => { try { sessionStorage.setItem(key, this.width); } catch {} };
    resize(272);
    try { const saved = Number(sessionStorage.getItem(key)); if (saved) resize(saved); } catch {}
    el.onpointerdown = e => { if (e.button === 0) el.setPointerCapture(e.pointerId); };
    el.onpointermove = e => {
      if (el.hasPointerCapture(e.pointerId)) resize(e.clientX - pane.getBoundingClientRect().left);
    };
    el.onlostpointercapture = save;
    el.onkeydown = e => {
      const width = {ArrowLeft: this.width - 16, ArrowRight: this.width + 16, Home: 200, End: 440}[e.key];
      if (width) { e.preventDefault(); resize(width); save(); }
    };
    this.restore = () => resize(this.width);
  },
  updated() { this.restore(); }
};

// Follow streaming output only while the reader is at the end.
export const FollowTranscript = {
  mounted() {
    const scroller = this.el, button = document.getElementById("jump-latest");
    let follow = true;
    const sync = () => { if (follow) scroller.scrollTop = scroller.scrollHeight; button.hidden = follow; };
    button.onclick = () => { follow = true; sync(); };
    scroller.onscroll = () => {
      follow = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop < 32;
      button.hidden = follow;
    };
    this.observer = new MutationObserver(sync);
    this.observer.observe(scroller, {subtree: true, childList: true, characterData: true});
    sync();
  },
  destroyed() { this.observer.disconnect(); }
};

// Desktop keyboard navigation for /inbox: j/k/arrows move across rows,
// n/p cycle through attention rows without intercepting Tab between controls.
export const InboxBrowser = {
  mounted() {
    this.selectedSid = null;

    const getRows = () => Array.from(this.el.querySelectorAll("a[data-inbox-row='true']"));

    const isEditable = target => {
      if (!target) return false;
      const tag = target.tagName;
      return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable;
    };

    this.applySelection = (rows, scrollIntoView = false) => {
      let activeRow = null;
      if (this.selectedSid) {
        activeRow = rows.find(r => r.dataset.sessionId === this.selectedSid) || null;
      }
      if (!activeRow && rows.length > 0) {
        activeRow = rows[0];
        this.selectedSid = activeRow.dataset.sessionId;
      }
      for (const row of rows) {
        const selected = row === activeRow;
        row.classList.toggle("is-selected", selected);
        row.setAttribute("aria-current", selected ? "true" : "false");
      }
      if (activeRow && scrollIntoView) {
        activeRow.scrollIntoView({block: "nearest"});
      }
      return activeRow;
    };

    const move = delta => {
      const rows = getRows();
      if (rows.length === 0) return;
      const currentIdx = rows.findIndex(r => r.dataset.sessionId === this.selectedSid);
      const nextIdx =
        currentIdx === -1
          ? (delta > 0 ? 0 : rows.length - 1)
          : (currentIdx + delta + rows.length) % rows.length;
      this.selectedSid = rows[nextIdx].dataset.sessionId;
      this.applySelection(rows, true);
    };

    const cycleAttention = direction => {
      const rows = getRows();
      const attentionRows = rows.filter(r => r.dataset.needsAttention === "true");
      if (attentionRows.length === 0) return;
      const currentIdx = attentionRows.findIndex(r => r.dataset.sessionId === this.selectedSid);
      const nextIdx =
        currentIdx === -1
          ? (direction > 0 ? 0 : attentionRows.length - 1)
          : (currentIdx + direction + attentionRows.length) % attentionRows.length;
      this.selectedSid = attentionRows[nextIdx].dataset.sessionId;
      this.applySelection(rows, true);
    };

    this.onKeydown = event => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (isEditable(event.target)) return;

      if (event.key === "j" || event.key === "ArrowDown") {
        event.preventDefault();
        move(1);
      } else if (event.key === "k" || event.key === "ArrowUp") {
        event.preventDefault();
        move(-1);
      } else if (event.key === "n" || event.key === "p") {
        const rows = getRows();
        if (rows.some(r => r.dataset.needsAttention === "true")) {
          event.preventDefault();
          cycleAttention(event.key === "p" ? -1 : 1);
        }
      } else if (event.key === "Enter") {
        if (event.target?.closest?.("button, a")) return;
        const rows = getRows();
        const selected = this.applySelection(rows, false);
        if (selected && event.target !== selected) {
          event.preventDefault();
          selected.click();
        }
      }
    };

    this.onPointerOver = event => {
      const row = event.target?.closest?.("a[data-inbox-row='true']");
      if (row && this.el.contains(row)) {
        this.selectedSid = row.dataset.sessionId;
        this.applySelection(getRows(), false);
      }
    };

    window.addEventListener("keydown", this.onKeydown);
    this.el.addEventListener("pointerover", this.onPointerOver);
    this.applySelection(getRows(), false);
  },

  updated() {
    const rows = Array.from(this.el.querySelectorAll("a[data-inbox-row='true']"));
    this.applySelection(rows, false);
  },

  destroyed() {
    if (this.onKeydown) window.removeEventListener("keydown", this.onKeydown);
    if (this.onPointerOver) this.el.removeEventListener("pointerover", this.onPointerOver);
  }
};
