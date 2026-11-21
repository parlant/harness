import {PaneSplitter, FollowTranscript, InboxBrowser} from "./workbench.js";
import {ReviewEditor} from "./review.js";
import {Inspector} from "./inspector.js";

(() => {
  const csrfMeta = document.querySelector("meta[name='csrf-token']");
  const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : "";

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
    PaneSplitter, FollowTranscript, InboxBrowser, Inspector, ReviewEditor,
    ComposerDraft: {
      mounted() {
        const reply = this.el.closest("details");
        this.reply = reply;
        this.onToggle = () => { if (reply.open) this.scheduleAutogrow?.(); };
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
          const k = draftKey(this.el);
          if (!k) return;
          try {
            window.localStorage.setItem(k, this.el.value);
          } catch (_err) {
            // Ignore storage errors.
          }
        };

        this.onKeydown = (event) => {
          if (event.key === "Enter" && event.shiftKey && !event.isComposing) {
            event.preventDefault();
            if (this.el.form) {
              this.el.form.requestSubmit(document.getElementById("send-btn"));
            }
          } else if (event.key === "Escape" && !event.isComposing) {
            event.preventDefault();
            const stop = document.getElementById("stop-btn");
            if (stop) stop.click();
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
          this.scheduleAutogrow?.();
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
        }
        this.scheduleAutogrow?.();
      },

      destroyed() {
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
