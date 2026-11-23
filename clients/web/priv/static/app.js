import {PaneSplitter, FollowTranscript, InboxBrowser} from "./workbench.js";
import {ReviewEditor} from "./review.js";
import {Inspector} from "./inspector.js";
import {ComposerCompleter, DirectoryComplete} from "./completion.js";

(() => {
  const csrfMeta = document.querySelector("meta[name='csrf-token']");
  const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : "";

  // Delegated clipboard copy for below-card message toolbar buttons.
  const copyTimers = new WeakMap();
  async function writeClipboard(text) {
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (_err) {
        // Fall back to execCommand below for non-HTTPS or restricted contexts.
      }
    }
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    ta.style.pointerEvents = "none";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (_err) {
      ok = false;
    }
    document.body.removeChild(ta);
    return ok;
  }

  document.addEventListener("click", event => {
    if (event.defaultPrevented || !(event.target instanceof Element)) return;
    const copyBtn = event.target.closest("[data-copy-btn]");
    if (!copyBtn) return;
    const text = copyBtn.dataset.copyText;
    if (typeof text !== "string" || text === "") return;
    event.preventDefault();
    writeClipboard(text).then(ok => {
      if (!ok) return;
      copyBtn.dataset.copied = "true";
      const prevTimer = copyTimers.get(copyBtn);
      if (prevTimer) window.clearTimeout(prevTimer);
      copyTimers.set(copyBtn, window.setTimeout(() => {
        delete copyBtn.dataset.copied;
        copyTimers.delete(copyBtn);
      }, 1800));
    });
  });

  // Global LiveView panel open/close events (works even when the composer is hidden, e.g. archived sessions).
  window.addEventListener("phx:open_panel", event => {
    const id = event.detail?.id;
    if (!id) return;
    const panel = document.getElementById(id);
    if (panel && typeof panel.showModal === "function" && !panel.open) {
      panel.showModal();
    }
  });

  window.addEventListener("phx:close_panel", event => {
    const id = event.detail?.id;
    if (!id) return;
    const panel = document.getElementById(id);
    if (panel && typeof panel.close === "function" && panel.open) {
      panel.close();
    }
  });

  // Native popovers and modal dialogs keep chrome out of the page's scroll flow.
  document.addEventListener("click", event => {
    if (event.defaultPrevented || !(event.target instanceof Element)) return;
    const target = event.target;
    const opener = target.closest("[data-open-panel]");
    const closer = target.closest("[data-close-panel]");
    const inspector = target.closest("[data-open-inspector]");
    if (opener) {
      const panel = document.getElementById(opener.dataset.openPanel);
      if (panel && !panel.open) panel.showModal();
    } else if (closer) {
      closer.closest("dialog")?.close();
    } else if (target.matches(".app-panel[open]")) {
      target.close();
    } else if (inspector) {
      document.getElementById("inspector-toggle")?.click();
    }
    const menu = target.closest("#app-menu");
    if (menu && target.closest("a, [data-dismiss-menu], [data-open-inspector]")) menu.hidePopover();
    target.closest("[data-panel-navigate]")?.closest("dialog")?.close();
  });

  // Mobile keyboards can shrink the visual viewport without resizing 100dvh.
  // Only retarget the shell while the composer is focused and unzoomed.
  const viewport = window.visualViewport;
  const fitKeyboard = () => {
    const root = document.documentElement;
    if (viewport?.scale === 1 && document.activeElement?.id === "prompt-input" &&
        matchMedia("(pointer: coarse)").matches && viewport.height < window.innerHeight - 100) {
      root.style.setProperty("--screen-height", `${Math.round(viewport.height)}px`);
    } else {
      root.style.removeProperty("--screen-height");
    }
  };
  viewport?.addEventListener("resize", fitKeyboard);
  document.addEventListener("focusin", fitKeyboard);
  document.addEventListener("focusout", () => requestAnimationFrame(fitKeyboard));

  function draftKey(el) {
    const sid = el.dataset.sessionId;
    const cid = el.dataset.conversationId;
    return sid && cid ? `hweb:draft:${sid}:${cid}` : null;
  }

  const Hooks = {
    PaneSplitter, FollowTranscript, InboxBrowser, Inspector, ReviewEditor, DirectoryComplete,
    ComposerDraft: {
      mounted() {
        const reply = this.el.closest("details");
        this.reply = reply;
        this.completer = new ComposerCompleter(this, this.el);
        this.onToggle = () => {
          if (reply.open) this.scheduleAutogrow?.();
          else this.completer?.dismiss();
        };
        reply.addEventListener("toggle", this.onToggle);
        const key = this.key = draftKey(this.el);
        if (key && this.el.value === "") {
          try {
            const saved = window.localStorage.getItem(key);
            if (saved) {
              this.el.value = saved;
              this.el.dispatchEvent(new Event("input", { bubbles: true }));
            }
          } catch (_err) {
            // Ignore localStorage access errors.
          }
        }

        // Older browsers need a measurement pass instead of CSS field-sizing.
        if (!CSS.supports("field-sizing", "content")) {
          const { el } = this;
          this.growFrame = null;
          this.scheduleAutogrow = () => {
            if (this.growFrame !== null) return;
            this.growFrame = window.requestAnimationFrame(() => {
              this.growFrame = null;
              const scrollTop = el.scrollTop;
              el.style.overflowY = "hidden";
              el.style.height = "0px";
              // Leave room for fractional line heights when the content exceeds the minimum.
              const height = el.scrollHeight;
              el.style.height = `${height > el.clientHeight ? height + 1 : height}px`;
              el.style.overflowY = "";
              el.scrollTop = scrollTop;
            });
          };

          let width = el.clientWidth;
          this.resizeObserver = new ResizeObserver(([entry]) => {
            const nextWidth = entry.contentRect.width;
            if (nextWidth !== width) {
              width = nextWidth;
              this.scheduleAutogrow();
            }
          });
          this.resizeObserver.observe(el.form);
        }

        this.onInput = () => {
          this.scheduleAutogrow?.();
          this.completer?.update(false);
          const k = draftKey(this.el);
          if (!k) return;
          try {
            window.localStorage.setItem(k, this.el.value);
          } catch (_err) {
            // Ignore storage errors.
          }
        };

        this.onKeydown = (event) => {
          if (this.completer?.handleKeydown(event)) {
            return;
          }
          if (event.key === "Enter" && (event.shiftKey || event.metaKey || event.ctrlKey) && !event.isComposing) {
            event.preventDefault();
            this.completer?.dismiss();
            if (this.el.form) {
              this.el.form.requestSubmit(document.getElementById("send-btn"));
            }
          } else if (event.key === "Escape" && !event.isComposing) {
            event.preventDefault();
            const cancelFork = document.getElementById("cancel-fork-edit-btn");
            const stop = document.getElementById("stop-btn");
            if (cancelFork) cancelFork.click();
            else if (stop) stop.click();
            else {
              reply.open = false;
              reply.querySelector("summary")?.focus({preventScroll: true});
            }
          }
        };

        this.el.addEventListener("input", this.onInput);
        this.el.addEventListener("keydown", this.onKeydown);
        this.scheduleAutogrow?.();

        this.handleEvent("clear_draft", ({ session_id, conversation_id }) => {
          if (session_id && conversation_id) {
            try {
              window.localStorage.removeItem(
                `hweb:draft:${session_id}:${conversation_id}`
              );
            } catch (_err) {
              // Ignore storage errors.
            }
          }
          this.el.value = "";
          this.completer?.dismiss();
          this.scheduleAutogrow?.();
        });

        this.handleEvent("set_draft", ({ session_id, conversation_id, text, open_reply }) => {
          const nextText = typeof text === "string" ? text : "";
          if (open_reply && reply && !reply.open) {
            reply.open = true;
          }
          this.el.value = nextText;
          if (session_id && conversation_id) {
            try {
              window.localStorage.setItem(
                `hweb:draft:${session_id}:${conversation_id}`,
                nextText
              );
            } catch (_err) {
              // Ignore storage errors.
            }
          }
          this.completer?.dismiss();
          this.scheduleAutogrow?.();
          if (open_reply) {
            this.el.focus({ preventScroll: true });
            this.el.setSelectionRange(nextText.length, nextText.length);
          }
        });

        this.handleEvent("open_panel", ({ id }) => {
          if (!id) return;
          const panel = document.getElementById(id);
          if (panel && typeof panel.showModal === "function" && !panel.open) {
            panel.showModal();
          }
        });

        this.handleEvent("close_panel", ({ id }) => {
          if (!id) return;
          const panel = document.getElementById(id);
          if (panel && typeof panel.close === "function" && panel.open) {
            panel.close();
          }
        });
      },

      updated() {
        const key = draftKey(this.el);
        if (key !== this.key) {
          this.key = key;
          this.el.value = "";
          try {
            if (key) this.el.value = window.localStorage.getItem(key) || "";
          } catch (_err) {
            // Ignore localStorage access errors.
          }
          this.completer?.dismiss();
        }
        this.completer?.refreshMeta();
        this.scheduleAutogrow?.();
      },

      destroyed() {
        this.completer?.destroy();
        this.reply.removeEventListener("toggle", this.onToggle);
        this.resizeObserver?.disconnect();
        if (this.growFrame != null) window.cancelAnimationFrame(this.growFrame);
        if (this.onInput) this.el.removeEventListener("input", this.onInput);
        if (this.onKeydown) this.el.removeEventListener("keydown", this.onKeydown);
      }
    }
  };

  if (window.Phoenix && window.LiveView) {
    const liveSocket = new window.LiveView.LiveSocket(
      "/live",
      window.Phoenix.Socket,
      {
        params: { _csrf_token: csrfToken },
        hooks: Hooks
      }
    );
    liveSocket.connect();
    window.liveSocket = liveSocket;
  }
})();
