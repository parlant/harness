/**
 * Pure, framework-free ConversationTranscript state reducer and JSON delta applier.
 * Safe for both browser ES modules and Node.js ESM tests.
 */

const UNSAFE_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isArrayIndex(segment) {
  if (typeof segment === "number") {
    return Number.isInteger(segment) && segment >= 0;
  }
  if (typeof segment === "string" && /^\d+$/.test(segment)) {
    return true;
  }
  return false;
}

function safeKey(segment) {
  const key = String(segment);
  if (UNSAFE_KEYS.has(key)) {
    throw new Error(`Unsafe doc path segment: ${key}`);
  }
  return key;
}

function getAtPath(root, path) {
  let cursor = root;
  for (const segment of path) {
    if (cursor === null || cursor === undefined) return undefined;
    if (Array.isArray(cursor) && isArrayIndex(segment)) {
      cursor = cursor[Number(segment)];
    } else if (typeof cursor === "object") {
      const key = safeKey(segment);
      if (!Object.hasOwn(cursor, key)) return undefined;
      cursor = cursor[key];
    } else {
      return undefined;
    }
  }
  return cursor;
}

function setAtPath(root, path, value) {
  if (path.length === 0) return value;

  const [head, ...tail] = path;

  if (Array.isArray(root) && isArrayIndex(head)) {
    const index = Number(head);
    const copy = root.slice();
    copy[index] = setAtPath(copy[index], tail, value);
    return copy;
  }

  const key = safeKey(head);
  const base = isPlainObject(root) ? { ...root } : {};
  base[key] = setAtPath(Object.hasOwn(base, key) ? base[key] : undefined, tail, value);
  return base;
}

function deleteAtPath(root, path) {
  if (path.length === 0) return undefined;
  if (root === null || root === undefined || typeof root !== "object") return root;

  const [head, ...tail] = path;

  if (tail.length === 0) {
    if (Array.isArray(root) && isArrayIndex(head)) {
      const index = Number(head);
      if (index < 0 || index >= root.length) return root;
      const copy = root.slice();
      copy.splice(index, 1);
      return copy;
    }
    const key = safeKey(head);
    if (!Object.hasOwn(root, key)) return root;
    const copy = { ...root };
    delete copy[key];
    return copy;
  }

  if (Array.isArray(root) && isArrayIndex(head)) {
    const index = Number(head);
    if (index < 0 || index >= root.length) return root;
    const nextChild = deleteAtPath(root[index], tail);
    if (nextChild === root[index]) return root;
    const copy = root.slice();
    copy[index] = nextChild;
    return copy;
  }

  const key = safeKey(head);
  if (!Object.hasOwn(root, key)) return root;
  const nextChild = deleteAtPath(root[key], tail);
  if (nextChild === root[key]) return root;
  return { ...root, [key]: nextChild };
}

/**
 * Applies compact JSON delta operations to a document immutably.
 *
 * Supported ops:
 * - ["replace", newValue] | ["r", newValue]
 * - ["set", pathArray, value]
 * - ["append_text", pathArray, deltaStr]
 * - ["delete", pathArray]
 */
export function applyDocOps(doc, ops) {
  if (!Array.isArray(ops) || ops.length === 0) return doc;

  let current = doc;
  for (const op of ops) {
    if (!Array.isArray(op) || op.length === 0) continue;
    const [kind, arg1, arg2] = op;

    if (kind === "replace" || kind === "r") {
      current = arg1;
    } else if (kind === "set") {
      const path = Array.isArray(arg1) ? arg1 : [];
      current = setAtPath(current, path, arg2);
    } else if (kind === "append_text") {
      const path = Array.isArray(arg1) ? arg1 : [];
      const delta = arg2 === undefined || arg2 === null ? "" : String(arg2);
      const prev = getAtPath(current, path);
      const nextText = (typeof prev === "string" ? prev : "") + delta;
      current = setAtPath(current, path, nextText);
    } else if (kind === "delete") {
      const path = Array.isArray(arg1) ? arg1 : [];
      current = deleteAtPath(current, path);
    }
  }

  return current;
}

function normalizeEntries(entries) {
  if (!Array.isArray(entries) || entries.length === 0) return [];
  const byId = new Map();
  for (const entry of entries) {
    if (!entry || entry.id === undefined || entry.id === null) continue;
    byId.set(String(entry.id), entry);
  }
  return Array.from(byId.values()).sort((a, b) => Number(a.id) - Number(b.id));
}

function normalizeDocs(docs) {
  const src = isPlainObject(docs) ? docs : {};
  return {
    live: isPlainObject(src.live) ? src.live : {},
    inbox: Array.isArray(src.inbox) ? src.inbox : [],
    agent: isPlainObject(src.agent) ? src.agent : {},
    usage: isPlainObject(src.usage) ? src.usage : {},
    ...src
  };
}

function applyDocOpsMap(docs, docOps) {
  if (!isPlainObject(docOps)) return docs;
  let nextDocs = docs;
  for (const [docName, ops] of Object.entries(docOps)) {
    if (!Array.isArray(ops) || ops.length === 0) continue;
    if (UNSAFE_KEYS.has(docName)) continue;
    if (nextDocs === docs) {
      nextDocs = { ...docs };
    }
    nextDocs[docName] = applyDocOps(nextDocs[docName], ops);
  }
  return nextDocs;
}

export class ConversationTranscript {
  constructor({ sessionId = null, conversationId = null } = {}) {
    this.sessionId = sessionId;
    this.conversationId = conversationId;
    this.seq = null;
    this.beforeEntryId = null;
    this.items = [];
    this.docs = normalizeDocs({});
  }

  get entries() {
    return this.items.filter((item) => item && item.kind !== "gap");
  }

  applySnapshot(frame) {
    if (!frame || typeof frame !== "object") {
      return { applied: false, gapInserted: false };
    }

    const snapEntries = normalizeEntries(frame.entries);
    const nextBefore = frame.before_entry_id ?? null;
    const nextDocs = normalizeDocs(frame.docs);
    let gapInserted = false;

    if (this.seq === null) {
      this.items = snapEntries;
      this.beforeEntryId = nextBefore;
      this.seq = frame.seq;
      this.docs = nextDocs;
      return { applied: true, gapInserted: false };
    }

    const existingEntries = this.entries;

    if (existingEntries.length === 0) {
      this.items = snapEntries;
      this.beforeEntryId = nextBefore;
      this.seq = frame.seq;
      this.docs = nextDocs;
      return { applied: true, gapInserted: false };
    }

    if (snapEntries.length === 0) {
      this.seq = frame.seq;
      this.docs = nextDocs;
      return { applied: true, gapInserted: false };
    }

    const firstSnapId = Number(snapEntries[0].id);
    const firstExistingId = Number(existingEntries[0].id);
    const lastExistingEntry = existingEntries[existingEntries.length - 1];
    const lastExistingId = Number(lastExistingEntry.id);

    if (firstSnapId <= firstExistingId) {
      this.items = snapEntries;
      this.beforeEntryId = nextBefore;
    } else if (
      firstSnapId <= lastExistingId + 1 ||
      nextBefore === null ||
      String(nextBefore) === String(lastExistingEntry.id)
    ) {
      const prefix = [];
      for (const item of this.items) {
        if (item.kind === "gap") {
          if (Number(item.to_inclusive) < firstSnapId) {
            prefix.push(item);
          }
        } else if (Number(item.id) < firstSnapId) {
          prefix.push(item);
        }
      }
      this.items = [...prefix, ...snapEntries];
    } else {
      const gap = {
        kind: "gap",
        from_exclusive: String(lastExistingEntry.id),
        to_inclusive: String(nextBefore)
      };
      this.items = [...this.items, gap, ...snapEntries];
      gapInserted = true;
    }

    this.seq = frame.seq;
    this.docs = nextDocs;
    return { applied: true, gapInserted };
  }

  applyCommit(frame) {
    if (!frame || typeof frame !== "object") return false;
    if (this.seq !== null && frame.seq <= this.seq) return false;

    const appended = normalizeEntries(frame.appended_entries);
    if (appended.length > 0) {
      const seen = new Set(this.entries.map((entry) => String(entry.id)));
      const toAdd = appended.filter((entry) => !seen.has(String(entry.id)));
      if (toAdd.length > 0) {
        this.items = [...this.items, ...toAdd];
      }
    }

    this.docs = applyDocOpsMap(this.docs, frame.doc_ops);
    this.seq = frame.seq;
    return true;
  }

  applyEphemeral(frame) {
    if (!frame || typeof frame !== "object") return false;
    if (this.seq === null || frame.base_seq !== this.seq) return false;

    this.docs = applyDocOpsMap(this.docs, frame.doc_ops);
    return true;
  }

  prependOlderPage(items, nextCursor) {
    const older = normalizeEntries(items);
    const seen = new Set(this.entries.map((entry) => String(entry.id)));
    const uniqueOlder = older.filter((entry) => !seen.has(String(entry.id)));

    if (uniqueOlder.length > 0) {
      this.items = [...uniqueOlder, ...this.items];
    }
    this.beforeEntryId = nextCursor ?? null;
    return uniqueOlder.length;
  }
}
