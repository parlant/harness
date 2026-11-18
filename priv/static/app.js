import { ConversationTranscript } from "./transcript.js";

class AuthRequiredError extends Error {
  constructor(message = "Authentication required") {
    super(message);
    this.name = "AuthRequiredError";
  }
}

const state = {
  environments: [],
  fsView: null,
  models: [],
  sessions: [],
  sessionDetail: null,
  selectedSessionId: null,
  selectedConversationId: null,
  transcript: null,
  eventSource: null,
  connToken: 0,
  loadingEarlier: false
};

const dom = {
  authBar: document.getElementById("auth-bar"),
  authForm: document.getElementById("auth-form"),
  authTokenInput: document.getElementById("auth-token-input"),
  authError: document.getElementById("auth-error"),

  toggleNewSessionBtn: document.getElementById("toggle-new-session-btn"),
  newSessionForm: document.getElementById("new-session-form"),
  newSessionEnv: document.getElementById("new-session-env"),
  newSessionId: document.getElementById("new-session-id"),
  newSessionCwd: document.getElementById("new-session-cwd"),
  newSessionModel: document.getElementById("new-session-model"),
  fsUpBtn: document.getElementById("fs-up-btn"),
  fsFolderSessions: document.getElementById("fs-folder-sessions"),
  fsDirsList: document.getElementById("fs-dirs-list"),
  cancelNewSessionBtn: document.getElementById("cancel-new-session-btn"),

  refreshSessionsBtn: document.getElementById("refresh-sessions-btn"),
  sessionsList: document.getElementById("sessions-list"),

  branchesSection: document.getElementById("branches-section"),
  branchesTree: document.getElementById("branches-tree"),

  configSection: document.getElementById("config-section"),
  modelSelect: document.getElementById("model-select"),
  thinkingSelect: document.getElementById("thinking-select"),
  configStatus: document.getElementById("config-status"),

  hdrSession: document.getElementById("hdr-session"),
  hdrCwd: document.getElementById("hdr-cwd"),
  hdrConv: document.getElementById("hdr-conv"),
  hdrSeq: document.getElementById("hdr-seq"),
  hdrUsage: document.getElementById("hdr-usage"),
  connBadge: document.getElementById("conn-badge"),
  stopBtn: document.getElementById("stop-btn"),

  errorBanner: document.getElementById("error-banner"),
  errorBannerText: document.getElementById("error-banner-text"),
  errorBannerDismiss: document.getElementById("error-banner-dismiss"),

  transcriptScroll: document.getElementById("transcript-scroll"),
  emptyState: document.getElementById("empty-state"),
  loadEarlierWrap: document.getElementById("load-earlier-wrap"),
  loadEarlierBtn: document.getElementById("load-earlier-btn"),
  entriesList: document.getElementById("entries-list"),

  liveRegion: document.getElementById("live-region"),
  liveGeneration: document.getElementById("live-generation"),
  liveTools: document.getElementById("live-tools"),
  liveInbox: document.getElementById("live-inbox"),
  runFailureBanner: document.getElementById("run-failure-banner"),

  composerForm: document.getElementById("composer-form"),
  promptInput: document.getElementById("prompt-input"),
  pendingStatus: document.getElementById("pending-status"),
  retryPendingBtn: document.getElementById("retry-pending-btn"),
  steerBtn: document.getElementById("steer-btn"),
  sendBtn: document.getElementById("send-btn")
};

function el(tag, options = {}, children = []) {
  const node = document.createElement(tag);
  if (options.className) node.className = options.className;
  if (options.text !== undefined) node.textContent = options.text;
  if (options.type) node.type = options.type;
  if (options.title) node.title = options.title;
  if (options.open) node.open = true;
  if (options.disabled) node.disabled = true;
  if (options.dataset) {
    for (const [k, v] of Object.entries(options.dataset)) {
      node.dataset[k] = String(v);
    }
  }
  for (const child of children) {
    if (child !== null && child !== undefined) {
      node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
    }
  }
  return node;
}

function generateRequestId() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function storageGet(store, key) {
  try {
    return store.getItem(key);
  } catch {
    return null;
  }
}

function storageSet(store, key, value) {
  try {
    store.setItem(key, value);
  } catch {
    // Ignore storage quota or private mode errors.
  }
}

function storageRemove(store, key) {
  try {
    store.removeItem(key);
  } catch {
    // Ignore storage errors.
  }
}

function pendingCommandKey(sid, cid) {
  return `h:pendingCommand:${sid}:${cid}`;
}

function getPendingCommand(sid, cid) {
  if (!sid || !cid) return null;
  const raw = storageGet(sessionStorage, pendingCommandKey(sid, cid));
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function setPendingCommand(sid, cid, record) {
  if (!sid || !cid) return;
  storageSet(sessionStorage, pendingCommandKey(sid, cid), JSON.stringify(record));
}

function clearPendingCommand(sid, cid) {
  if (!sid || !cid) return;
  storageRemove(sessionStorage, pendingCommandKey(sid, cid));
}

function draftKey(sid, cid) {
  return `h:draft:${sid}:${cid}`;
}

function showError(message) {
  dom.errorBannerText.textContent = message;
  dom.errorBanner.hidden = false;
}

function clearError() {
  dom.errorBanner.hidden = true;
  dom.errorBannerText.textContent = "";
}

function showAuthBar(errorText = "") {
  dom.authBar.hidden = false;
  if (errorText) {
    dom.authError.textContent = errorText;
    dom.authError.hidden = false;
  } else {
    dom.authError.textContent = "";
    dom.authError.hidden = true;
  }
  dom.authTokenInput.focus();
}

function hideAuthBar() {
  dom.authBar.hidden = true;
  dom.authError.hidden = true;
  dom.authError.textContent = "";
  dom.authTokenInput.value = "";
}

function setConnBadge(status, label) {
  dom.connBadge.className = `conn-badge status-${status}`;
  dom.connBadge.textContent = label;
}

async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  const response = await fetch(path, {
    ...options,
    headers,
    credentials: "same-origin"
  });

  if (response.status === 401) {
    showAuthBar();
    throw new AuthRequiredError();
  }

  const text = await response.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text };
    }
  }

  if (!response.ok) {
    const err = new Error(
      (data && (data.error || data.message || data.reason)) ||
        `HTTP ${response.status} ${response.statusText}`
    );
    err.status = response.status;
    err.data = data;
    throw err;
  }

  return data;
}

function extractHashToken() {
  const hash = window.location.hash;
  if (!hash || hash.length <= 1) return null;
  const raw = hash.slice(1);
  const params = new URLSearchParams(raw);
  const token = params.get("token");
  if (token) return token;
  const match = raw.match(/(?:^|&)token=([^&]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

async function exchangeOwnerToken(token) {
  const response = await fetch("/api/v1/auth/session", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token })
  });

  if (!response.ok) {
    let detail = `Authentication failed (${response.status})`;
    try {
      const payload = await response.json();
      if (payload && (payload.error || payload.message)) {
        detail = payload.error || payload.message;
      }
    } catch {
      // Ignore parse failure.
    }
    throw new Error(detail);
  }
}

async function bootstrapAuthFromHash() {
  const token = extractHashToken();
  if (!token) return;
  history.replaceState(null, "", window.location.pathname + window.location.search);
  try {
    await exchangeOwnerToken(token);
    hideAuthBar();
  } catch (err) {
    showAuthBar(err.message);
  }
}

async function loadEnvironments() {
  try {
    const data = await apiFetch("/api/v1/environments");
    state.environments = Array.isArray(data?.environments) ? data.environments : [];
    renderEnvironmentSelector();
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Failed to load environments: ${err.message}`);
    }
  }
}

function renderEnvironmentSelector() {
  if (!dom.newSessionEnv) return;
  const current = dom.newSessionEnv.value || "host";
  dom.newSessionEnv.replaceChildren();
  const envs =
    state.environments.length > 0
      ? state.environments
      : [{ id: "host", label: "Local Host", default_cwd: "" }];

  for (const env of envs) {
    const opt = el("option", { text: env.label ? `${env.label} (${env.id})` : env.id });
    opt.value = env.id;
    dom.newSessionEnv.appendChild(opt);
  }
  dom.newSessionEnv.value = envs.some((e) => e.id === current) ? current : envs[0].id;
}

async function browseDirectory(path = "", envId = null) {
  const targetEnv = envId || dom.newSessionEnv?.value || "host";
  const qs = new URLSearchParams({ env_id: targetEnv });
  if (path) qs.set("path", path);

  try {
    const view = await apiFetch(`/api/v1/fs?${qs.toString()}`);
    state.fsView = view;
    if (view?.path && dom.newSessionCwd) {
      dom.newSessionCwd.value = view.path;
    }
    renderFolderBrowser();
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Browse failed: ${err.message}`);
    }
  }
}

function renderFolderBrowser() {
  const view = state.fsView;
  if (!view || !dom.fsDirsList) return;

  if (dom.fsUpBtn) {
    dom.fsUpBtn.disabled = !view.parent_path;
  }

  if (dom.fsFolderSessions) {
    dom.fsFolderSessions.replaceChildren();
    const direct = Array.isArray(view.sessions) ? view.sessions : [];
    if (direct.length > 0) {
      dom.fsFolderSessions.hidden = false;
      dom.fsFolderSessions.appendChild(
        el("div", {
          className: "fs-sessions-head",
          text: `Sessions in this folder (${direct.length})`
        })
      );
      for (const s of direct.slice(0, 5)) {
        const resumeBtn = el(
          "button",
          { type: "button", className: "fs-session-btn" },
          [
            el("span", { className: "session-title", text: s.title || s.session_id }),
            el("span", { className: "badge mono", text: s.active ? "active" : "resume" })
          ]
        );
        resumeBtn.addEventListener("click", async () => {
          dom.newSessionForm.hidden = true;
          await selectSession(s.session_id);
        });
        dom.fsFolderSessions.appendChild(resumeBtn);
      }
    } else {
      dom.fsFolderSessions.hidden = true;
    }
  }

  dom.fsDirsList.replaceChildren();
  const dirs = Array.isArray(view.directories) ? view.directories : [];
  if (dirs.length === 0) {
    dom.fsDirsList.appendChild(
      el("li", { className: "session-cwd", text: "No subdirectories." })
    );
    return;
  }

  for (const dir of dirs) {
    const badges = [];
    if (Array.isArray(dir.markers) && dir.markers.length > 0) {
      badges.push(
        el("span", { className: "fs-marker mono", text: dir.markers.slice(0, 2).join(" ") })
      );
    }
    if (dir.subtree_session_count > 0) {
      badges.push(
        el("span", {
          className: `badge mono${dir.active_session_count > 0 ? " badge-ok" : ""}`,
          text: `${dir.subtree_session_count} sess`
        })
      );
    }

    const row = el(
      "button",
      { type: "button", className: "fs-dir-btn" },
      [
        el("span", { className: "mono", text: `${dir.name}/` }),
        el("span", { className: "fs-dir-badges" }, badges)
      ]
    );
    row.addEventListener("click", () => browseDirectory(dir.path, view.env_id));
    dom.fsDirsList.appendChild(el("li", {}, [row]));
  }
}

async function loadModels() {
  try {
    const data = await apiFetch("/api/v1/models");
    state.models = Array.isArray(data?.models) ? data.models : [];
    renderConfigSelectors();
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Failed to load models: ${err.message}`);
    }
  }
}

async function loadSessions({ autoSelect = true } = {}) {
  try {
    const data = await apiFetch("/api/v1/sessions");
    state.sessions = Array.isArray(data?.sessions) ? data.sessions : [];
    renderSessionsList();

    if (autoSelect && state.sessions.length > 0) {
      const savedSid = storageGet(localStorage, "h:selectedSession");
      const target =
        state.sessions.find((s) => s.session_id === state.selectedSessionId) ||
        state.sessions.find((s) => s.session_id === savedSid) ||
        state.sessions[0];
      if (target && target.session_id !== state.selectedSessionId) {
        await selectSession(target.session_id);
      }
    }
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Failed to load sessions: ${err.message}`);
    }
  }
}

async function selectSession(sessionId, preferredConversationId = null) {
  clearError();
  state.selectedSessionId = sessionId;
  storageSet(localStorage, "h:selectedSession", sessionId);
  renderSessionsList();

  try {
    const detail = await apiFetch(`/api/v1/sessions/${encodeURIComponent(sessionId)}`);
    state.sessionDetail = detail;
    const conversations = Array.isArray(detail?.conversations) ? detail.conversations : [];
    const savedCid = storageGet(localStorage, `h:selectedConv:${sessionId}`);
    const rootCid = detail?.session?.root_conversation_id || "1";

    const chosen =
      conversations.find((c) => String(c.id) === String(preferredConversationId)) ||
      conversations.find((c) => String(c.id) === String(savedCid)) ||
      conversations.find((c) => String(c.id) === String(rootCid)) ||
      conversations[0];

    const cid = chosen ? String(chosen.id) : String(rootCid);
    selectConversation(cid);
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Failed to load session ${sessionId}: ${err.message}`);
    }
  }
}

function closeEventSource() {
  state.connToken += 1;
  if (state.eventSource) {
    state.eventSource.close();
    state.eventSource = null;
  }
}

function selectConversation(conversationId) {
  const sid = state.selectedSessionId;
  if (!sid) return;

  closeEventSource();
  state.selectedConversationId = String(conversationId);
  storageSet(localStorage, `h:selectedConv:${sid}`, state.selectedConversationId);

  state.transcript = new ConversationTranscript({
    sessionId: sid,
    conversationId: state.selectedConversationId
  });

  const savedDraft = storageGet(localStorage, draftKey(sid, state.selectedConversationId)) || "";
  dom.promptInput.value = savedDraft;
  dom.promptInput.disabled = false;
  dom.sendBtn.disabled = false;
  dom.emptyState.hidden = true;

  renderBranchTree();
  renderPendingCommandStatus();
  renderAll();
  connectEventStream(sid, state.selectedConversationId);
}

function connectEventStream(sid, cid) {
  const token = state.connToken + 1;
  state.connToken = token;
  setConnBadge("reconnecting", "Connecting…");

  const url = `/api/v1/sessions/${encodeURIComponent(sid)}/conversations/${encodeURIComponent(cid)}/events`;
  const es = new EventSource(url);
  state.eventSource = es;

  es.addEventListener("open", () => {
    if (state.connToken !== token) return;
    setConnBadge("connected", "Connected");
  });

  es.addEventListener("error", () => {
    if (state.connToken !== token) return;
    setConnBadge("reconnecting", "Reconnecting");
    if (es.readyState === EventSource.CLOSED) {
      apiFetch("/api/v1/sessions").catch(() => {});
    }
  });

  es.addEventListener("snapshot", (event) => {
    if (state.connToken !== token || !state.transcript) return;
    try {
      const frame = JSON.parse(event.data);
      const nearBottom = isNearBottom();
      const firstLoad = state.transcript.seq === null;
      state.transcript.applySnapshot(frame);
      setConnBadge("connected", "Connected");
      renderAll();
      if (firstLoad || nearBottom) {
        scrollToBottom();
      }
    } catch (err) {
      showError(`Invalid snapshot frame: ${err.message}`);
    }
  });

  es.addEventListener("commit", (event) => {
    if (state.connToken !== token || !state.transcript) return;
    try {
      const frame = JSON.parse(event.data);
      const nearBottom = isNearBottom();
      const applied = state.transcript.applyCommit(frame);
      if (applied) {
        renderAll();
        if (nearBottom) {
          scrollToBottom();
        }
      }
    } catch (err) {
      showError(`Invalid commit frame: ${err.message}`);
    }
  });

  es.addEventListener("ephemeral", (event) => {
    if (state.connToken !== token || !state.transcript) return;
    try {
      const frame = JSON.parse(event.data);
      const nearBottom = isNearBottom();
      const applied = state.transcript.applyEphemeral(frame);
      if (applied) {
        renderLiveRegion();
        renderHeader();
        if (nearBottom) {
          scrollToBottom();
        }
      }
    } catch {
      // Ignore malformed ephemeral frame.
    }
  });
}

function isNearBottom() {
  const elScroll = dom.transcriptScroll;
  return elScroll.scrollHeight - elScroll.scrollTop - elScroll.clientHeight < 100;
}

function scrollToBottom() {
  dom.transcriptScroll.scrollTop = dom.transcriptScroll.scrollHeight;
}

function isRunActive() {
  return Boolean(state.transcript?.docs?.live?.run);
}

async function sendCommand(command, args, { idempotentPending = false } = {}) {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  if (!sid || !cid) return null;

  const basePayload = {
    version: 1,
    command,
    conversation_id: cid,
    args
  };
  const fingerprint = JSON.stringify(basePayload);

  let requestId = generateRequestId();
  if (idempotentPending) {
    const existing = getPendingCommand(sid, cid);
    if (existing && existing.fingerprint === fingerprint && existing.request_id) {
      requestId = existing.request_id;
    }
    setPendingCommand(sid, cid, {
      request_id: requestId,
      fingerprint,
      body: { ...basePayload, request_id: requestId }
    });
    renderPendingCommandStatus();
  }

  const body = { ...basePayload, request_id: requestId };

  try {
    const receipt = await apiFetch(`/api/v1/sessions/${encodeURIComponent(sid)}/commands`, {
      method: "POST",
      body: JSON.stringify(body)
    });
    if (idempotentPending) {
      clearPendingCommand(sid, cid);
      renderPendingCommandStatus();
    }
    return receipt;
  } catch (err) {
    if (idempotentPending && err.status && err.status >= 400 && err.status < 500 && err.status !== 408 && err.status !== 429) {
      clearPendingCommand(sid, cid);
      renderPendingCommandStatus();
    } else if (idempotentPending) {
      renderPendingCommandStatus(err.message);
    }
    throw err;
  }
}

async function retryPendingCommand() {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  const pending = getPendingCommand(sid, cid);
  if (!pending || !pending.body) return;

  try {
    clearError();
    await apiFetch(`/api/v1/sessions/${encodeURIComponent(sid)}/commands`, {
      method: "POST",
      body: JSON.stringify(pending.body)
    });
    clearPendingCommand(sid, cid);
    renderPendingCommandStatus();
  } catch (err) {
    if (err.status && err.status >= 400 && err.status < 500) {
      clearPendingCommand(sid, cid);
    }
    renderPendingCommandStatus(err.message);
    if (!(err instanceof AuthRequiredError)) {
      showError(`Retry failed: ${err.message}`);
    }
  }
}

async function submitPrompt({ whenBusy, whenIdle }) {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  if (!sid || !cid) return;

  const text = dom.promptInput.value;
  if (!text.trim()) return;

  clearError();
  try {
    await sendCommand(
      "submit",
      {
        type: "input",
        content: [{ type: "text", text }],
        when_busy: whenBusy,
        when_idle: whenIdle
      },
      { idempotentPending: true }
    );
    dom.promptInput.value = "";
    storageRemove(localStorage, draftKey(sid, cid));
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Submit failed: ${err.message}`);
    }
  }
}

async function continueRun() {
  clearError();
  try {
    await sendCommand("submit", { type: "continue" }, { idempotentPending: true });
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Continue failed: ${err.message}`);
    }
  }
}

async function abortRun() {
  if (!isRunActive()) return;
  try {
    await sendCommand("abort", {});
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Abort failed: ${err.message}`);
    }
  }
}

async function forkAtEntry(entryId) {
  const sid = state.selectedSessionId;
  if (!sid) return;
  clearError();
  try {
    const receipt = await sendCommand("fork", { at_entry_id: String(entryId) });
    if (receipt && receipt.conversation_id) {
      await selectSession(sid, String(receipt.conversation_id));
    }
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Fork failed: ${err.message}`);
    }
  }
}

async function forkAndSubmit(entryId, text) {
  const sid = state.selectedSessionId;
  if (!sid) return;
  const receipt = await sendCommand("fork_and_submit", {
    at_entry_id: String(entryId),
    content: [{ type: "text", text }]
  });
  if (receipt && receipt.conversation_id) {
    await selectSession(sid, String(receipt.conversation_id));
  }
  return receipt;
}

async function configureAgent() {
  const model = dom.modelSelect.value;
  const thinking = dom.thinkingSelect.value;
  dom.configStatus.textContent = "Saving…";
  dom.configStatus.hidden = false;
  try {
    await sendCommand("configure", { model, thinking });
    dom.configStatus.textContent = "Saved";
  } catch (err) {
    dom.configStatus.textContent = `Error: ${err.message}`;
    if (!(err instanceof AuthRequiredError)) {
      showError(`Configure failed: ${err.message}`);
    }
  }
}

async function loadEarlierMessages() {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  const cursor = state.transcript?.beforeEntryId;
  if (!sid || !cid || !cursor || state.loadingEarlier) return;

  state.loadingEarlier = true;
  dom.loadEarlierBtn.disabled = true;
  dom.loadEarlierBtn.textContent = "Loading…";

  try {
    const prevHeight = dom.transcriptScroll.scrollHeight;
    const prevTop = dom.transcriptScroll.scrollTop;
    const url = `/api/v1/sessions/${encodeURIComponent(sid)}/conversations/${encodeURIComponent(cid)}/entries?order=desc&cursor=${encodeURIComponent(cursor)}&limit=50`;
    const data = await apiFetch(url);
    state.transcript.prependOlderPage(data?.items || [], data?.next_cursor ?? null);
    renderEntries();
    renderLoadEarlier();
    const nextHeight = dom.transcriptScroll.scrollHeight;
    dom.transcriptScroll.scrollTop = prevTop + (nextHeight - prevHeight);
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Failed to load earlier entries: ${err.message}`);
    }
  } finally {
    state.loadingEarlier = false;
    dom.loadEarlierBtn.disabled = false;
    dom.loadEarlierBtn.textContent = "Load earlier";
  }
}

function renderPendingCommandStatus(errText = "") {
  const pending = getPendingCommand(state.selectedSessionId, state.selectedConversationId);
  if (!pending) {
    dom.pendingStatus.hidden = true;
    dom.pendingStatus.textContent = "";
    dom.retryPendingBtn.hidden = true;
    return;
  }
  dom.pendingStatus.textContent = errText
    ? `Pending retry (${pending.request_id.slice(0, 8)}…): ${errText}`
    : `Pending request ${pending.request_id.slice(0, 8)}…`;
  dom.pendingStatus.hidden = false;
  dom.retryPendingBtn.hidden = false;
}

function renderSessionsList() {
  dom.sessionsList.replaceChildren();
  if (state.sessions.length === 0) {
    dom.sessionsList.appendChild(
      el("li", { className: "session-cwd", text: "No sessions yet." })
    );
    return;
  }

  for (const session of state.sessions) {
    const isActiveSelection = session.session_id === state.selectedSessionId;
    const dotClass =
      session.status === "quarantined"
        ? "dot dot-quarantined"
        : session.active
          ? "dot dot-active"
          : "dot";

    const btn = el(
      "button",
      {
        type: "button",
        className: `session-item${isActiveSelection ? " is-active" : ""}`
      },
      [
        el("div", { className: "session-row" }, [
          el("span", {
            className: "session-title",
            text: session.title || session.session_id
          }),
          el("span", { className: dotClass, title: session.status || "ok" })
        ]),
        el("div", {
          className: "session-cwd mono",
          text: session.cwd || ""
        })
      ]
    );
    btn.addEventListener("click", () => selectSession(session.session_id));
    dom.sessionsList.appendChild(el("li", {}, [btn]));
  }
}

function renderBranchTree() {
  const conversations = state.sessionDetail?.conversations;
  if (!state.selectedSessionId || !Array.isArray(conversations) || conversations.length === 0) {
    dom.branchesSection.hidden = true;
    dom.branchesTree.replaceChildren();
    return;
  }

  dom.branchesSection.hidden = false;
  const byId = new Map();
  const childrenMap = new Map();
  for (const conv of conversations) {
    const id = String(conv.id);
    byId.set(id, conv);
    childrenMap.set(id, []);
  }

  const roots = [];
  for (const conv of conversations) {
    const id = String(conv.id);
    const parentId = conv.parent?.conversation_id ? String(conv.parent.conversation_id) : null;
    if (parentId && childrenMap.has(parentId)) {
      childrenMap.get(parentId).push(conv);
    } else {
      roots.push(conv);
    }
  }

  const sortById = (a, b) => Number(a.id) - Number(b.id);
  roots.sort(sortById);
  for (const kids of childrenMap.values()) {
    kids.sort(sortById);
  }

  function buildList(nodes) {
    const ul = el("ul");
    for (const conv of nodes) {
      const id = String(conv.id);
      const isSelected = id === state.selectedConversationId;
      const metaParts = [];
      if (conv.parent && conv.parent.at !== undefined) {
        metaParts.push(`@ #${conv.parent.at}`);
      }
      if (conv.owner && typeof conv.owner === "string" && conv.owner !== "ownerless") {
        metaParts.push(conv.owner);
      }

      const btn = el(
        "button",
        {
          type: "button",
          className: `branch-btn${isSelected ? " is-active" : ""}`
        },
        [
          el("span", { className: "mono", text: `#${id}` }),
          metaParts.length > 0
            ? el("span", { className: "branch-meta mono", text: metaParts.join(" · ") })
            : null
        ]
      );
      btn.addEventListener("click", () => selectConversation(id));

      const li = el("li", {}, [btn]);
      const kids = childrenMap.get(id) || [];
      if (kids.length > 0) {
        li.appendChild(buildList(kids));
      }
      ul.appendChild(li);
    }
    return ul;
  }

  dom.branchesTree.replaceChildren(buildList(roots));
}

const PROVIDER_LABELS = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  google_vertex: "Google Vertex",
  google: "Google",
  deepseek: "DeepSeek",
  openrouter: "OpenRouter",
  ollama: "Ollama"
};

function populateModelSelect(selectEl, selectedId = "") {
  if (!selectEl) return;
  selectEl.replaceChildren();
  const seenModels = new Set();
  const groups = new Map();

  for (const model of state.models) {
    const id = model.id;
    if (!id) continue;
    seenModels.add(id);
    const providerKey = model.provider || id.split(":")[0] || "other";
    if (!groups.has(providerKey)) {
      groups.set(providerKey, []);
    }
    const shortId = id.includes(":") ? id.split(":").slice(1).join(":") : id;
    const label =
      model.name && model.name !== shortId ? `${model.name} (${shortId})` : id;
    const opt = el("option", { text: label });
    opt.value = id;
    groups.get(providerKey).push(opt);
  }

  if (groups.size <= 1) {
    for (const opts of groups.values()) {
      for (const opt of opts) selectEl.appendChild(opt);
    }
  } else {
    for (const [providerKey, opts] of groups.entries()) {
      const groupLabel = PROVIDER_LABELS[providerKey] || providerKey;
      const optgroup = el("optgroup", { attrs: { label: groupLabel } });
      for (const opt of opts) optgroup.appendChild(opt);
      selectEl.appendChild(optgroup);
    }
  }

  if (selectedId && !seenModels.has(selectedId)) {
    const opt = el("option", { text: selectedId });
    opt.value = selectedId;
    selectEl.appendChild(opt);
  }

  if (selectedId) {
    selectEl.value = selectedId;
  } else if (state.models.length > 0 && state.models[0].id) {
    selectEl.value = state.models[0].id;
  }
}

function renderConfigSelectors() {
  populateModelSelect(
    dom.newSessionModel,
    dom.newSessionModel?.value || state.models[0]?.id || ""
  );

  if (!state.selectedSessionId) {
    dom.configSection.hidden = true;
    return;
  }
  dom.configSection.hidden = false;

  const agent = state.transcript?.docs?.agent || {};
  const currentModel = agent.model || state.models[0]?.id || "";
  const currentThinking = agent.thinking || "off";

  populateModelSelect(dom.modelSelect, currentModel);

  if (
    Array.from(dom.thinkingSelect.options).some((opt) => opt.value === currentThinking)
  ) {
    dom.thinkingSelect.value = currentThinking;
  }
}

function formatUsage(usage) {
  if (!usage || typeof usage !== "object") return "";
  const input = usage.input_tokens ?? usage.input ?? 0;
  const output = usage.output_tokens ?? usage.output ?? 0;
  const total = usage.total_tokens ?? input + output;
  if (!total && !input && !output) return "";
  const cost =
    typeof usage.cost === "number" && usage.cost > 0 ? ` · $${usage.cost.toFixed(4)}` : "";
  return `tokens: ${input} in / ${output} out${cost}`;
}

function renderHeader() {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  const sessionObj =
    state.sessionDetail?.session ||
    state.sessions.find((s) => s.session_id === sid) ||
    null;

  if (!sid) {
    dom.hdrSession.textContent = "No session";
    dom.hdrCwd.hidden = true;
    dom.hdrConv.hidden = true;
    dom.hdrSeq.hidden = true;
    dom.hdrUsage.hidden = true;
    dom.stopBtn.hidden = true;
    dom.steerBtn.hidden = true;
    return;
  }

  dom.hdrSession.textContent = sid;
  if (sessionObj?.cwd) {
    dom.hdrCwd.textContent = sessionObj.cwd;
    dom.hdrCwd.hidden = false;
  } else {
    dom.hdrCwd.hidden = true;
  }

  if (cid) {
    dom.hdrConv.textContent = `conv #${cid}`;
    dom.hdrConv.hidden = false;
  } else {
    dom.hdrConv.hidden = true;
  }

  const seq = state.transcript?.seq;
  if (seq !== null && seq !== undefined) {
    dom.hdrSeq.textContent = `seq ${seq}`;
    dom.hdrSeq.hidden = false;
  } else {
    dom.hdrSeq.hidden = true;
  }

  const usageText = formatUsage(state.transcript?.docs?.usage);
  if (usageText) {
    dom.hdrUsage.textContent = usageText;
    dom.hdrUsage.hidden = false;
  } else {
    dom.hdrUsage.hidden = true;
  }

  const busy = isRunActive();
  dom.stopBtn.hidden = !busy;
  dom.steerBtn.hidden = !busy;
}

function renderLoadEarlier() {
  const hasCursor = Boolean(state.transcript?.beforeEntryId);
  dom.loadEarlierWrap.hidden = !hasCursor;
}

function extractParts(data) {
  const thinkingParts = [];
  const textParts = [];
  const otherParts = [];

  if (!data || typeof data !== "object") {
    return { thinkingParts, textParts, otherParts };
  }

  if (typeof data.thinking === "string" && data.thinking.length > 0) {
    thinkingParts.push(data.thinking);
  }
  if (typeof data.reasoning === "string" && data.reasoning.length > 0) {
    thinkingParts.push(data.reasoning);
  }

  if (typeof data.content === "string" && data.content.length > 0) {
    textParts.push(data.content);
  } else if (Array.isArray(data.content)) {
    for (const part of data.content) {
      if (typeof part === "string") {
        textParts.push(part);
      } else if (part && typeof part === "object") {
        if (part.type === "thinking" || part.type === "reasoning") {
          if (part.thinking || part.text) thinkingParts.push(part.thinking || part.text);
        } else if (part.type === "text") {
          if (part.text !== undefined) textParts.push(String(part.text));
        } else {
          otherParts.push(part);
        }
      }
    }
  }

  if (typeof data.text === "string" && data.text.length > 0 && textParts.length === 0) {
    textParts.push(data.text);
  }

  return { thinkingParts, textParts, otherParts };
}

function formatJson(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function renderEntryCard(item) {
  if (item.kind === "gap") {
    return el("div", {
      className: "entry-gap mono",
      text: `Skipped entries (${item.from_exclusive} .. ${item.to_inclusive}] during reconnect`
    });
  }

  const entry = item;
  const kind = entry.kind || "entry";
  const data = entry.data && typeof entry.data === "object" ? entry.data : {};

  const headerBadges = [
    el("span", { className: "role-label", text: kind }),
    el("span", { className: "entry-id mono", text: `#${entry.id}` })
  ];

  if (data.aborted) {
    headerBadges.push(el("span", { className: "badge badge-warn", text: "aborted" }));
  }

  if (kind === "tool_result") {
    const toolName = data.tool_name || data.name || "tool";
    headerBadges.push(el("span", { className: "badge mono", text: toolName }));
    if (data.is_error || data.error) {
      headerBadges.push(el("span", { className: "badge badge-danger", text: "error" }));
    }
    if (data.duration_ms !== undefined && data.duration_ms !== null) {
      headerBadges.push(el("span", { className: "badge mono", text: `${data.duration_ms}ms` }));
    }
  }

  const forkBtn = el("button", {
    type: "button",
    className: "btn btn-sm btn-ghost fork-btn",
    text: "Fork here"
  });
  forkBtn.addEventListener("click", () => forkAtEntry(entry.id));

  const header = el("div", { className: "entry-header" }, [
    el("div", { className: "entry-header-left" }, headerBadges),
    forkBtn
  ]);

  const bodyChildren = [];

  if (kind === "compaction" || kind === "reset" || kind === "handoff") {
    const note = data.summary || data.note || data.reason || formatJson(data);
    bodyChildren.push(el("p", { className: "entry-text", text: String(note) }));
    return el("article", { className: "entry-card entry-marker" }, [
      header,
      el("div", { className: "entry-body" }, bodyChildren)
    ]);
  }

  if (kind === "tool_result") {
    const { textParts } = extractParts(data);
    const output =
      textParts.length > 0
        ? textParts.join("\n")
        : data.output !== undefined
          ? formatJson(data.output)
          : data.result !== undefined
            ? formatJson(data.result)
            : data.error !== undefined
              ? formatJson(data.error)
              : formatJson(data);

    const details = el("details", { className: "collapsible" }, [
      el("summary", {
        text: data.tool_call_id ? `Output (${data.tool_call_id})` : "Output"
      }),
      el("pre", { className: "code-pre", text: String(output) })
    ]);
    bodyChildren.push(details);
  } else {
    const { thinkingParts, textParts, otherParts } = extractParts(data);

    if (thinkingParts.length > 0) {
      bodyChildren.push(
        el("details", { className: "collapsible" }, [
          el("summary", { text: "Thinking" }),
          el("pre", { className: "code-pre", text: thinkingParts.join("\n\n") })
        ])
      );
    }

    if (textParts.length > 0) {
      bodyChildren.push(el("p", { className: "entry-text", text: textParts.join("\n") }));
    }

    if (Array.isArray(data.tool_calls) && data.tool_calls.length > 0) {
      const tcNodes = data.tool_calls.map((tc) => {
        const args = tc.arguments ?? tc.args ?? tc.input ?? {};
        return el("div", { className: "tool-call-card" }, [
          el("div", { className: "tool-call-head" }, [
            el("span", { className: "badge mono", text: tc.name || "tool" }),
            tc.id ? el("span", { className: "entry-id mono", text: String(tc.id) }) : null
          ]),
          el("pre", { className: "code-pre", text: formatJson(args) })
        ]);
      });
      bodyChildren.push(el("div", { className: "tool-calls-list" }, tcNodes));
    }

    if (otherParts.length > 0) {
      bodyChildren.push(el("pre", { className: "code-pre", text: formatJson(otherParts) }));
    }

    if (bodyChildren.length === 0) {
      bodyChildren.push(el("pre", { className: "code-pre", text: formatJson(data) }));
    }
  }

  return el("article", { className: `entry-card entry-${kind}` }, [
    header,
    el("div", { className: "entry-body" }, bodyChildren)
  ]);
}

function renderEntries() {
  dom.entriesList.replaceChildren();
  const items = state.transcript?.items || [];
  for (const item of items) {
    dom.entriesList.appendChild(renderEntryCard(item));
  }
}

function renderLiveRegion() {
  const docs = state.transcript?.docs;
  if (!docs) {
    dom.liveRegion.hidden = true;
    return;
  }

  const live = docs.live && typeof docs.live === "object" ? docs.live : {};
  const inbox = Array.isArray(docs.inbox) ? docs.inbox : [];

  let anyVisible = false;

  // 1. Active generation / streaming assistant message
  const gen = live.generation;
  if (gen || live.run) {
    anyVisible = true;
    dom.liveGeneration.hidden = false;
    const msg = gen?.message && typeof gen.message === "object" ? gen.message : gen || {};
    const { thinkingParts, textParts } = extractParts(msg);
    const toolCalls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];

    const headBadges = [
      el("span", { className: "role-label", text: "assistant (live)" })
    ];
    if (live.run?.turns !== undefined) {
      headBadges.push(
        el("span", { className: "badge mono", text: `turn ${live.run.turns}` })
      );
    }
    if (gen?.retry) {
      headBadges.push(
        el("span", {
          className: "badge badge-warn mono",
          text: `retry ${gen.retry.attempt ?? ""}`.trim()
        })
      );
    }

    const children = [el("div", { className: "entry-header-left" }, headBadges)];

    if (thinkingParts.length > 0) {
      children.push(
        el("details", { className: "collapsible", open: true }, [
          el("summary", { text: "Thinking (streaming)" }),
          el("pre", { className: "code-pre", text: thinkingParts.join("\n\n") })
        ])
      );
    }

    if (textParts.length > 0) {
      children.push(el("p", { className: "entry-text", text: textParts.join("\n") }));
    } else if (thinkingParts.length === 0 && toolCalls.length === 0) {
      children.push(
        el("span", { className: "entry-id mono", text: "Streaming…" })
      );
    }

    if (toolCalls.length > 0) {
      const tcNodes = toolCalls.map((tc) =>
        el("div", { className: "tool-call-card" }, [
          el("div", { className: "tool-call-head" }, [
            el("span", { className: "badge mono", text: tc.name || "tool" }),
            tc.id ? el("span", { className: "entry-id mono", text: String(tc.id) }) : null
          ]),
          el("pre", {
            className: "code-pre",
            text: formatJson(tc.arguments ?? tc.args ?? tc.input ?? "")
          })
        ])
      );
      children.push(el("div", { className: "tool-calls-list" }, tcNodes));
    }

    dom.liveGeneration.replaceChildren(...children);
  } else {
    dom.liveGeneration.hidden = true;
    dom.liveGeneration.replaceChildren();
  }

  // 2. Running tool slots
  const rawTools = live.tools;
  const toolSlots = Array.isArray(rawTools)
    ? rawTools
    : rawTools && typeof rawTools === "object"
      ? Object.entries(rawTools).map(([id, slot]) => ({ id, ...slot }))
      : [];

  if (toolSlots.length > 0) {
    anyVisible = true;
    dom.liveTools.hidden = false;
    const nodes = [el("div", { className: "role-label", text: "Running Tools" })];
    for (const slot of toolSlots) {
      const out = slot.output ?? slot.stdout ?? slot.text ?? "";
      nodes.push(
        el("div", { className: "tool-call-card" }, [
          el("div", { className: "tool-call-head" }, [
            el("span", { className: "badge mono", text: slot.name || "tool" }),
            slot.status ? el("span", { className: "badge badge-ok", text: String(slot.status) }) : null,
            slot.id ? el("span", { className: "entry-id mono", text: String(slot.id) }) : null
          ]),
          out ? el("pre", { className: "code-pre", text: String(out) }) : null
        ])
      );
    }
    dom.liveTools.replaceChildren(...nodes);
  } else {
    dom.liveTools.hidden = true;
    dom.liveTools.replaceChildren();
  }

  // 3. Queued inbox items
  if (inbox.length > 0) {
    anyVisible = true;
    dom.liveInbox.hidden = false;
    const nodes = [el("div", { className: "role-label", text: `Queued (${inbox.length})` })];
    for (const item of inbox) {
      const { textParts } = extractParts(item);
      const summary = textParts.join(" ") || formatJson(item);
      const mode = item.when_busy ? `[${item.when_busy}] ` : "";
      nodes.push(el("div", { className: "inbox-item", text: `${mode}${summary}` }));
    }
    dom.liveInbox.replaceChildren(...nodes);
  } else {
    dom.liveInbox.hidden = true;
    dom.liveInbox.replaceChildren();
  }

  // 4. Sticky run_failure / compaction_failure banner
  const failure = live.run_failure || live.compaction_failure;
  if (failure) {
    anyVisible = true;
    dom.runFailureBanner.hidden = false;
    const isCompaction = !live.run_failure && Boolean(live.compaction_failure);
    const reason =
      typeof failure === "string"
        ? failure
        : failure.reason || (isCompaction ? "compaction_failure" : "run_failure");
    const detail =
      typeof failure === "object" ? failure.detail || failure.message || "" : "";

    const continueBtn = el("button", {
      type: "button",
      className: "btn btn-sm btn-primary",
      text: "Continue Run"
    });
    continueBtn.addEventListener("click", () => continueRun());

    dom.runFailureBanner.replaceChildren(
      el("div", { className: "run-failure-info" }, [
        el("div", {
          className: "run-failure-title",
          text: `${isCompaction ? "Compaction failed" : "Run paused"}: ${reason}`
        }),
        detail ? el("div", { className: "run-failure-detail", text: String(detail) }) : null
      ]),
      continueBtn
    );
  } else {
    dom.runFailureBanner.hidden = true;
    dom.runFailureBanner.replaceChildren();
  }

  dom.liveRegion.hidden = !anyVisible;
}

function renderAll() {
  renderHeader();
  renderLoadEarlier();
  renderEntries();
  renderLiveRegion();
  renderConfigSelectors();
}

// Event bindings
dom.authForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const token = dom.authTokenInput.value.trim();
  if (!token) return;
  try {
    await exchangeOwnerToken(token);
    hideAuthBar();
    await Promise.all([loadEnvironments(), loadModels(), loadSessions()]);
    if (state.selectedSessionId && state.selectedConversationId) {
      connectEventStream(state.selectedSessionId, state.selectedConversationId);
    }
  } catch (err) {
    showAuthBar(err.message);
  }
});

dom.toggleNewSessionBtn.addEventListener("click", async () => {
  dom.newSessionForm.hidden = !dom.newSessionForm.hidden;
  if (!dom.newSessionForm.hidden) {
    const active = state.sessions.find((s) => s.session_id === state.selectedSessionId);
    const startPath = dom.newSessionCwd.value.trim() || active?.cwd || "";
    const startEnv = active?.env_id || dom.newSessionEnv?.value || "host";
    if (dom.newSessionEnv) dom.newSessionEnv.value = startEnv;
    await browseDirectory(startPath, startEnv);
  }
});

if (dom.fsUpBtn) {
  dom.fsUpBtn.addEventListener("click", () => {
    if (state.fsView?.parent_path) {
      browseDirectory(state.fsView.parent_path, state.fsView.env_id);
    }
  });
}

if (dom.newSessionEnv) {
  dom.newSessionEnv.addEventListener("change", () => {
    browseDirectory("", dom.newSessionEnv.value);
  });
}

dom.cancelNewSessionBtn.addEventListener("click", () => {
  dom.newSessionForm.hidden = true;
});

dom.newSessionForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const sessionId = dom.newSessionId.value.trim();
  const cwd = dom.newSessionCwd.value.trim();
  const envId = dom.newSessionEnv?.value || "host";
  if (!cwd) return;

  clearError();
  try {
    const selectedModel = dom.newSessionModel?.value || state.models[0]?.id || "";
    const body = {
      version: 1,
      request_id: generateRequestId(),
      env_id: envId,
      cwd,
      ...(sessionId ? { session_id: sessionId } : {}),
      ...(selectedModel ? { agent: { model: selectedModel } } : {})
    };
    const res = await apiFetch("/api/v1/sessions", {
      method: "POST",
      body: JSON.stringify(body)
    });
    dom.newSessionForm.hidden = true;
    dom.newSessionId.value = "";
    await loadSessions({ autoSelect: false });
    const createdSid = res?.session?.session_id || sessionId;
    await selectSession(createdSid);
  } catch (err) {
    if (!(err instanceof AuthRequiredError)) {
      showError(`Create session failed: ${err.message}`);
    }
  }
});

dom.refreshSessionsBtn.addEventListener("click", () => loadSessions({ autoSelect: false }));

dom.modelSelect.addEventListener("change", () => configureAgent());
dom.thinkingSelect.addEventListener("change", () => configureAgent());

dom.stopBtn.addEventListener("click", () => abortRun());
dom.errorBannerDismiss.addEventListener("click", () => clearError());
dom.loadEarlierBtn.addEventListener("click", () => loadEarlierMessages());
dom.retryPendingBtn.addEventListener("click", () => retryPendingCommand());

dom.promptInput.addEventListener("input", () => {
  const sid = state.selectedSessionId;
  const cid = state.selectedConversationId;
  if (sid && cid) {
    storageSet(localStorage, draftKey(sid, cid), dom.promptInput.value);
  }
});

dom.promptInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    submitPrompt({ whenBusy: "follow_up", whenIdle: "start" });
  } else if (event.key === "Escape" && isRunActive()) {
    event.preventDefault();
    abortRun();
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && isRunActive() && event.target !== dom.promptInput) {
    event.preventDefault();
    abortRun();
  }
});

dom.composerForm.addEventListener("submit", (event) => {
  event.preventDefault();
  submitPrompt({ whenBusy: "follow_up", whenIdle: "start" });
});

dom.steerBtn.addEventListener("click", () => {
  submitPrompt({ whenBusy: "steer", whenIdle: "reject" });
});

// Expose helpers for debugging/testing if needed without polluting global UX
window.__H_APP__ = { state, forkAndSubmit };

async function init() {
  await bootstrapAuthFromHash();
  await Promise.all([loadEnvironments(), loadModels(), loadSessions({ autoSelect: true })]);
}

init();
