import {PaneSplitter, FollowTranscript, InboxBrowser} from "./workbench.js";
import {ReviewEditor} from "./review.js";
import {Inspector} from "./inspector.js";

(() => {
  const csrfMeta = document.querySelector("meta[name='csrf-token']");
  const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : "";

  function draftKey(el) {
    const sid = el.dataset.sessionId;
    const cid = el.dataset.conversationId;
    return sid && cid ? `hweb:draft:${sid}:${cid}` : null;
  }

  const Hooks = {
    PaneSplitter, FollowTranscript, InboxBrowser, Inspector, ReviewEditor,
    ComposerDraft: {
      mounted() {
        const key = draftKey(this.el);
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
              this.el.form.dispatchEvent(
                new Event("submit", { bubbles: true, cancelable: true })
              );
            }
          } else if (event.key === "Escape") {
            const stopBtn = document.getElementById("stop-btn");
            if (stopBtn) stopBtn.click();
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
        this.scheduleAutogrow?.();
      },

      destroyed() {
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
