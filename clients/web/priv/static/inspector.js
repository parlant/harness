// Only tag names, element IDs and sibling positions — never serialize DOM,
// form values, URL queries, cookies or page text into target descriptions.
function locator(el) {
  const path = [];
  while (el && el !== document.body && !el.hasAttribute("data-phx-session")) {
    if (el.id) { path.unshift("#" + CSS.escape(el.id)); break; }
    const siblings = [...el.parentElement.children].filter(n => n.localName === el.localName);
    path.unshift(`${el.localName}:nth-of-type(${siblings.indexOf(el) + 1})`);
    el = el.parentElement;
  }
  return path.join(" > ") || "body";
}

function jpeg(source, width, height) {
  if (!width || !height) throw Error("The selection is not visible.");
  const scale = Math.min(1, 1200 / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  canvas.getContext("2d").drawImage(source, 0, 0, canvas.width, canvas.height);
  const image = canvas.toDataURL("image/jpeg", 0.8);
  if (image.length > 524288) throw Error("Crop a smaller area and try again.");
  return image;
}

// Region Capture rejects a crop target from a different tab. Never fall back
// to drawing an unverified full screen/window frame.
async function captureElement(el, signal) {
  const stream = await navigator.mediaDevices.getDisplayMedia({
    video: {displaySurface: "browser"}, audio: false, preferCurrentTab: true
  });
  const stop = () => stream.getTracks().forEach(track => track.stop());
  signal.addEventListener("abort", stop, {once: true});
  try {
    signal.throwIfAborted();
    const [track] = stream.getVideoTracks();
    if (!track?.cropTo || track.getSettings().displaySurface !== "browser") throw Error();
    await track.cropTo(await CropTarget.fromElement(el));
    const video = document.createElement("video");
    video.muted = true;
    video.srcObject = stream;
    await video.play();
    return jpeg(video, video.videoWidth, video.videoHeight);
  } finally {
    stop();
    signal.removeEventListener("abort", stop);
  }
}

export const Inspector = {
  mounted() {
    const root = this.el, $ = sel => root.querySelector(sel);
    const panel = $("#inspector-panel"), toggle = $("#inspector-toggle"), form = $("form");
    const target = $("#inspect-target"), preview = $("#inspect-preview"), status = $("#inspect-status");
    const capture = $('[data-action="capture"]');
    const scope = new AbortController(), {signal} = scope;
    let selection, selectedEl, picking = false, image, busy = false, sending = false, open = false;
    let request = crypto.randomUUID();
    const outline = document.createElement("div");
    outline.className = "inspect-highlight";
    outline.hidden = true;
    document.body.append(outline);
    // Only the mode survives a full browser reload; private drafts stay in memory.
    const key = "hweb:inspector:";
    const remember = (name, value) => { try { sessionStorage.setItem(key + name, value); } catch {} };
    const recall = name => { try { return sessionStorage.getItem(key + name); } catch { return null; } };
    const refresh = () => {
      capture.disabled = !selectedEl?.isConnected || busy || sending;
      form.elements.note.readOnly = sending;
      form.elements.attachment.disabled = sending || busy;
      $('[data-action="remove"]').disabled = sending || busy;
      for (const btn of form.querySelectorAll("button[type=submit]")) btn.disabled = busy || sending;
    };
    const setOpen = value => {
      open = value;
      panel.hidden = !value;
      toggle.hidden = value;
      toggle.setAttribute("aria-expanded", String(value));
      remember("open", value ? "yes" : "no");
      if (value || this.watching) this.pushEvent(value ? "watch" : "unwatch", {}).catch(() => {});
      this.watching = value;
      refresh();
    };
    const finishPick = () => {
      picking = false;
      document.documentElement.classList.remove("inspect-picking");
      outline.hidden = true;
      panel.hidden = !open;
      refresh();
    };
    const setImage = data => {
      image = data;
      preview.hidden = !data;
      if (data) preview.querySelector("img").src = data;
      else preview.querySelector("img").removeAttribute("src");
      form.elements.attachment.value = "";
      request = crypto.randomUUID();
    };
    const attach = async task => {
      if (busy || sending) return;
      busy = true;
      refresh();
      try { const data = await task(); if (!signal.aborted) { setImage(data); status.textContent = "Review the screenshot before sending."; } }
      catch (error) { status.textContent = error.message || "Capture unavailable. Paste or attach a cropped screenshot instead."; }
      finally { busy = false; refresh(); }
    };
    const attachFile = file => attach(async () => {
      if (!file || !["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 8 * 1024 * 1024)
        throw Error("Choose a PNG, JPEG or WebP under 8 MiB.");
      const bitmap = await createImageBitmap(file);
      try { return jpeg(bitmap, bitmap.width, bitmap.height); } finally { bitmap.close(); }
    });
    root.addEventListener("click", e => {
      if (e.target === toggle) { setOpen(true); form.elements.note.focus(); }
      switch (e.target.closest("[data-action]")?.dataset.action) {
        case "close": finishPick(); setOpen(false); toggle.focus(); break;
        case "pick":
          if (busy || sending) return;
          picking = true; panel.hidden = true;
          toggle.hidden = false; toggle.textContent = "Cancel pick (Esc)";
          document.documentElement.classList.add("inspect-picking"); break;
        case "remove": setImage(null); break;
        case "capture":
          if (!window.CropTarget || !navigator.mediaDevices?.getDisplayMedia) {
            status.textContent = "Tab capture is unavailable here. Paste or attach a cropped screenshot.";
            return;
          }
          // Hide the feedback window so it cannot obscure the crop.
          attach(async () => {
            root.hidden = true;
            try { return await captureElement(selectedEl, signal); }
            catch { throw Error("No screenshot captured. Share this tab, or paste/attach a cropped screenshot."); }
            finally { root.hidden = false; }
          });
      }
    }, {signal});
    const cancelPick = () => { finishPick(); toggle.textContent = "Inspect UI"; toggle.hidden = open; };
    window.addEventListener("pointermove", e => {
      if (!picking) return;
      const rect = e.target.getBoundingClientRect();
      Object.assign(outline.style, {left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px`});
      outline.hidden = root.contains(e.target);
    }, {capture: true, signal});
    window.addEventListener("pointerdown", e => {
      if (picking) { e.preventDefault(); e.stopImmediatePropagation(); }
    }, {capture: true, signal});
    window.addEventListener("click", e => {
      if (!picking) return;
      e.preventDefault(); e.stopImmediatePropagation();
      if (!root.contains(e.target)) {
        selectedEl = e.target;
        selection = {path: location.pathname, target: locator(selectedEl)};
        target.textContent = `${selection.path} · ${selection.target}`;
        setImage(null);
        status.textContent = "Element selected. Add feedback or capture its visible area.";
      }
      cancelPick(); form.elements.note.focus();
    }, {capture: true, signal});
    window.addEventListener("keydown", e => {
      if (e.key === "Escape" && picking) { e.preventDefault(); cancelPick(); form.elements.note.focus(); }
    }, {capture: true, signal});
    window.addEventListener("phx:page-loading-stop", () => {
      // Keep the note anchored to the originally selected page.
      if (selectedEl && selection.path !== location.pathname) selectedEl = null;
      refresh();
    }, {signal});
    form.elements.attachment.onchange = e => { if (e.target.files.length) attachFile(e.target.files[0]); };
    form.addEventListener("paste", e => {
      const file = [...e.clipboardData.files].find(f => f.type.startsWith("image/"));
      if (file) { e.preventDefault(); attachFile(file); }
    }, {signal});
    form.oninput = () => { request = crypto.randomUUID(); };
    form.onsubmit = async e => {
      e.preventDefault();
      if (sending || busy) return;
      const action = e.submitter?.value || "save";
      const payload = {...(selection || {path: location.pathname, target: "page"}), note: form.elements.note.value,
        action, request_id: request, image: image?.split(",")[1] || null};
      sending = true; refresh();
      try {
        const reply = await this.pushEvent("feedback", payload);
        if (!reply.ok) { status.textContent = reply.error; return; }
        form.reset(); setImage(null);
        status.textContent = action === "save" ? "Note saved. No run started." : "Sent. Follow the run in the feedback session.";
      } catch { status.textContent = "Not confirmed. Check the feedback session before retrying."; }
      finally { sending = false; refresh(); }
    };
    setOpen(recall("open") === "yes");
    this.sync = () => { panel.hidden = !open || picking; refresh(); };
    this.cleanup = () => { scope.abort(); finishPick(); outline.remove(); };
  },
  updated() { this.sync(); },
  reconnected() { if (this.watching) this.pushEvent("watch", {}).catch(() => {}); },
  destroyed() { this.cleanup(); }
};
