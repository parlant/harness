import {PaneSplitter, FollowTranscript, InboxBrowser} from "./workbench.js";
import {ReviewEditor} from "./review.js";
import {Inspector} from "./inspector.js";
import {Completer, DirectoryComplete} from "./completion.js";

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

  // Position row action popovers relative to their 3-dot trigger button.
  document.addEventListener("toggle", event => {
    const menu = event.target;
    if (!(menu instanceof Element) || !menu.matches(".inbox-row-actions-menu[popover]")) return;
    if (event.newState !== "open") return;
    const trigger = document.querySelector(`[popovertarget="${CSS.escape(menu.id)}"]`);
    if (!trigger) return;
    const rect = trigger.getBoundingClientRect();
    const gap = 4;
    const menuWidth = menu.offsetWidth || 176;
    const menuHeight = menu.offsetHeight || 160;
    const left = Math.max(8, Math.min(rect.right - menuWidth, window.innerWidth - menuWidth - 8));
    const spaceBelow = window.innerHeight - rect.bottom - gap - 8;
    const top = spaceBelow >= menuHeight || rect.top < menuHeight + gap + 8
      ? Math.min(rect.bottom + gap, window.innerHeight - menuHeight - 8)
      : Math.max(8, rect.top - menuHeight - gap);
    menu.style.left = `${Math.round(left)}px`;
    menu.style.top = `${Math.round(top)}px`;
  }, true);

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
    const menu = target.closest("[popover].app-menu");
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
    SessionSidebar: {
      mounted() {
        const key = "hweb:session-sidebar";
        this.sidebarEvents = new AbortController();
        const {signal} = this.sidebarEvents;
        let open = false;
        try { open = localStorage.getItem(key) === "open"; } catch {}

        const narrow = matchMedia("(max-width: 860px)");
        const trigger = () => this.el.querySelector("#session-details-button");
        this.renderSidebar = () => {
          this.el.toggleAttribute("data-sidebar-open", open);
          this.el.querySelector("#session-details").hidden = !open;
          trigger().setAttribute("aria-expanded", String(open));
        };
        const setOpen = (value, returnFocus = true) => {
          open = value;
          this.renderSidebar();
          try { localStorage.setItem(key, open ? "open" : "closed"); } catch {}
          if (!open && returnFocus) trigger().focus({preventScroll: true});
        };
        this.el.addEventListener("click", event => {
          if (event.target.closest("[data-session-sidebar-toggle]")) {
            setOpen(!open);
          } else if (open && narrow.matches && event.button === 0 &&
              !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey &&
              event.target.closest("#session-sidebar-inbox-tree a[data-session-id], #sidebar-parent-lineage a")) {
            setOpen(false, false);
          }
        }, {signal});
        this.el.addEventListener("keydown", event => {
          if (event.key === "Escape" && !event.defaultPrevented && open &&
              event.target.closest("#session-details, #session-details-button") &&
              !this.el.querySelector(".app-menu:popover-open")) {
            event.preventDefault();
            setOpen(false);
          }
        }, {signal});
        this.renderSidebar();
      },
      updated() { this.renderSidebar(); },
      destroyed() { this.sidebarEvents.abort(); }
    },
    SessionTags: {
      mounted() {
        const input = this.el.elements.tags;
        this.onTagKeydown = event => {
          if (event.key === "," && !event.isComposing && event.keyCode !== 229) {
            event.preventDefault();
            if (input.value.trim()) this.el.requestSubmit();
          }
        };
        input.addEventListener("keydown", this.onTagKeydown);
        this.handleEvent("session_tags_added", ({value}) => {
          if (input.value === value) input.value = "";
        });
      },
      destroyed() { this.el.elements.tags.removeEventListener("keydown", this.onTagKeydown); }
    },
    ComposerDraft: {
      mounted() {
        const reply = this.el.closest("details");
        this.reply = reply;
        this.completer = new Completer(this, this.el);
        this.onToggle = () => {
          if (reply.open) {
            this.scheduleAutogrow?.();
            if (!reply.contains(document.activeElement) || document.activeElement.closest("summary")) {
              this.el.focus({ preventScroll: true });
            }
          } else {
            this.completer?.dismiss();
          }
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
          const k = draftKey(this.el);
          if (!k || this.el.dataset.forkEdit === "true") return;
          try {
            window.localStorage.setItem(k, this.el.value);
          } catch (_err) {
            // Ignore storage errors.
          }
        };

        this.onKeydown = (event) => {
          if (event.defaultPrevented || this.completer.composing || event.isComposing || event.keyCode === 229) return;
          if (event.key === "Enter" && (event.shiftKey || event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            this.completer?.dismiss();
            if (this.el.form) {
              this.el.form.requestSubmit(document.getElementById("send-btn"));
            }
          } else if (event.key === "Escape") {
            event.preventDefault();
            const cancelFork = document.getElementById("cancel-fork-edit-btn");
            const stop = reply.querySelector("#composer-stop-btn");
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

        this.handleEvent("clear_draft", ({ session_id, conversation_id, preserve_saved }) => {
          if (session_id && conversation_id && !preserve_saved) {
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

        this.handleEvent("set_draft", ({ session_id, conversation_id, text, open_reply, fork_edit }) => {
          const nextText = typeof text === "string" ? text : "";
          if (open_reply && reply && !reply.open) {
            reply.open = true;
          }
          this.el.value = nextText;
          if (session_id && conversation_id && !fork_edit) {
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
        this.completer?.refresh();
        this.scheduleAutogrow?.();
      },

      disconnected() {
        this.completer?.dismiss();
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

  window.HWebExtensionHooks = window.HWebExtensionHooks || {};
  window.registerHWebHooks = (hooks) => Object.assign(window.HWebExtensionHooks, hooks);

  function connectLiveSocket(hooks) {
    if (window.Phoenix && window.LiveView) {
      const liveSocket = new window.LiveView.LiveSocket(
        "/live",
        window.Phoenix.Socket,
        {
          params: { _csrf_token: csrfToken },
          hooks
        }
      );
      liveSocket.connect();
      window.liveSocket = liveSocket;
    }
  }

  async function bootLiveSocket() {
    const extMeta = document.querySelector("meta[name='h-ext-scripts']");
    let srcs = [];
    if (extMeta) {
      try {
        const parsed = JSON.parse(extMeta.getAttribute("content") || "[]");
        if (Array.isArray(parsed)) srcs = parsed;
      } catch (err) {
        console.error("Failed to parse extension scripts metadata", err);
      }
    }

    if (srcs.length === 0) {
      connectLiveSocket({ ...window.HWebExtensionHooks, ...Hooks });
      return;
    }

    const extHooks = {};
    await Promise.all(
      srcs.map(async src => {
        if (typeof src === "string" && src.startsWith("/ext-assets/")) {
          try {
            const mod = await import(src);
            if (mod?.hooks) Object.assign(extHooks, mod.hooks);
            if (mod?.default?.hooks) Object.assign(extHooks, mod.default.hooks);
          } catch (err) {
            console.error("Failed to load extension script", src, err);
          }
        }
      })
    );

    connectLiveSocket({ ...window.HWebExtensionHooks, ...extHooks, ...Hooks });
  }

  bootLiveSocket();
})();
