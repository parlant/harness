(() => {
  const csrfMeta = document.querySelector("meta[name='csrf-token']");
  const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : "";

  function draftKey(el) {
    const sid = el.dataset.sessionId;
    const cid = el.dataset.conversationId;
    return sid && cid ? `hweb:draft:${sid}:${cid}` : null;
  }

  const Hooks = {
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

        this.onInput = () => {
          const k = draftKey(this.el);
          if (!k) return;
          try {
            window.localStorage.setItem(k, this.el.value);
          } catch (_err) {
            // Ignore storage errors.
          }
        };

        this.onKeydown = (event) => {
          if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
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
        });
      },

      destroyed() {
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
