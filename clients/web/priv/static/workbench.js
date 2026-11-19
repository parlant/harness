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
