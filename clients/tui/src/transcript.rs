use crate::protocol::{CommitFrame, EphemeralFrame, SnapshotFrame, TranscriptEntry};
use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

const UNSAFE_DOC_KEYS: &[&str] = &["__proto__", "constructor", "prototype"];

#[derive(Debug, Clone, PartialEq)]
pub enum CommitOutcome {
    Applied {
        appended_entries: Vec<TranscriptEntry>,
    },
    Stale,
    Gap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EphemeralOutcome {
    Applied,
    Ignored,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunFailureInfo {
    pub reason: String,
    pub code: Option<String>,
    pub message: Option<String>,
    pub is_compaction: bool,
}

#[derive(Debug, Clone)]
pub struct TranscriptState {
    pub session_id: Option<String>,
    pub conversation_id: Option<String>,
    pub seq: Option<u64>,
    pub entries: Vec<TranscriptEntry>,
    pub entry_ids: HashSet<String>,
    pub has_more: bool,
    pub before_entry_id: Option<String>,
    pub committed_docs: Map<String, Value>,
    pub docs: Map<String, Value>,
}

impl Default for TranscriptState {
    fn default() -> Self {
        Self::new(None, None)
    }
}

impl TranscriptState {
    pub fn new(session_id: Option<String>, conversation_id: Option<String>) -> Self {
        let docs = default_docs();
        Self {
            session_id,
            conversation_id,
            seq: None,
            entries: Vec::new(),
            entry_ids: HashSet::new(),
            has_more: false,
            before_entry_id: None,
            committed_docs: docs.clone(),
            docs,
        }
    }

    pub fn apply_snapshot(&mut self, frame: SnapshotFrame) {
        if let Some(sid) = frame.session_id {
            self.session_id = Some(sid);
        }
        if let Some(cid) = frame.conversation_id {
            self.conversation_id = Some(cid);
        }

        let entries = normalize_entries(frame.entries);
        let entry_ids = entries.iter().map(|e| e.id.clone()).collect();
        let before_entry_id = frame.before_entry_id.filter(|s| !s.is_empty());
        let has_more = frame.has_more.unwrap_or(before_entry_id.is_some());
        let docs = normalize_docs(frame.docs);

        self.seq = Some(frame.seq);
        self.entries = entries;
        self.entry_ids = entry_ids;
        self.before_entry_id = before_entry_id;
        self.has_more = has_more;
        self.committed_docs = docs.clone();
        self.docs = docs;
    }

    pub fn apply_commit(&mut self, frame: CommitFrame) -> CommitOutcome {
        let Some(cur_seq) = self.seq else {
            return CommitOutcome::Gap;
        };

        if frame.seq <= cur_seq {
            return CommitOutcome::Stale;
        }

        if let Some(prev_seq) = frame.prev_seq {
            if prev_seq != cur_seq {
                return CommitOutcome::Gap;
            }
        } else if frame.seq > cur_seq + 1 {
            return CommitOutcome::Gap;
        }

        let normalized = normalize_entries(frame.appended_entries);
        let mut new_entries = Vec::new();
        for entry in normalized {
            if self.entry_ids.insert(entry.id.clone()) {
                new_entries.push(entry);
            }
        }
        self.entries.extend(new_entries.iter().cloned());

        if let Some(doc_ops) = frame.doc_ops.as_ref() {
            apply_doc_ops_map(&mut self.committed_docs, doc_ops);
        }

        self.docs = self.committed_docs.clone();
        self.seq = Some(frame.seq);

        CommitOutcome::Applied {
            appended_entries: new_entries,
        }
    }

    pub fn apply_ephemeral(&mut self, frame: EphemeralFrame) -> EphemeralOutcome {
        let Some(cur_seq) = self.seq else {
            return EphemeralOutcome::Ignored;
        };
        if frame.base_seq != cur_seq {
            return EphemeralOutcome::Ignored;
        }

        if let Some(doc_ops) = frame.doc_ops.as_ref() {
            apply_doc_ops_map(&mut self.docs, doc_ops);
        } else if let Some(ops) = frame.ops.as_ref() {
            if !ops.is_empty() {
                let current_live = self
                    .docs
                    .get("live")
                    .cloned()
                    .unwrap_or_else(|| Value::Object(Map::new()));
                let next_live = apply_doc_ops(current_live, ops);
                self.docs.insert("live".to_string(), next_live);
            }
        }

        EphemeralOutcome::Applied
    }

    pub fn prepend_older_page(
        &mut self,
        items: Vec<TranscriptEntry>,
        next_cursor: Option<String>,
    ) -> usize {
        let normalized = normalize_entries(items);
        let mut unique_older = Vec::new();
        for entry in normalized {
            if self.entry_ids.insert(entry.id.clone()) {
                unique_older.push(entry);
            }
        }
        let added = unique_older.len();
        if added > 0 {
            unique_older.extend(std::mem::take(&mut self.entries));
            self.entries = unique_older;
        }
        let cursor = next_cursor.filter(|s| !s.is_empty());
        self.has_more = cursor.is_some();
        self.before_entry_id = cursor;
        added
    }

    pub fn live_doc(&self) -> Option<&Map<String, Value>> {
        self.docs.get("live").and_then(Value::as_object)
    }

    pub fn is_run_active(&self) -> bool {
        let Some(live) = self.live_doc() else {
            return false;
        };
        if live.get("run").is_some_and(|v| !v.is_null()) {
            return true;
        }
        if live.get("generation").is_some_and(|v| !v.is_null()) {
            return true;
        }
        if let Some(tools) = live.get("tools") {
            match tools {
                Value::Object(m) if !m.is_empty() => return true,
                Value::Array(a) if !a.is_empty() => return true,
                _ => {}
            }
        }
        false
    }

    pub fn inbox_len(&self) -> usize {
        self.docs
            .get("inbox")
            .and_then(Value::as_array)
            .map_or(0, Vec::len)
    }

    pub fn run_failure(&self) -> Option<RunFailureInfo> {
        let live = self.live_doc()?;
        let (val, is_compaction) =
            if let Some(rf) = live.get("run_failure").filter(|v| !v.is_null()) {
                (rf, false)
            } else {
                let cf = live.get("compaction_failure").filter(|v| !v.is_null())?;
                (cf, true)
            };

        match val {
            Value::String(s) => Some(RunFailureInfo {
                reason: s.clone(),
                code: None,
                message: None,
                is_compaction,
            }),
            Value::Object(map) => {
                let reason = map
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or(if is_compaction {
                        "compaction_failure"
                    } else {
                        "run_failure"
                    })
                    .to_string();
                let code = map.get("code").and_then(Value::as_str).map(str::to_string);
                let message = map
                    .get("message")
                    .or_else(|| map.get("detail"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
                Some(RunFailureInfo {
                    reason,
                    code,
                    message,
                    is_compaction,
                })
            }
            _ => Some(RunFailureInfo {
                reason: if is_compaction {
                    "compaction_failure"
                } else {
                    "run_failure"
                }
                .to_string(),
                code: None,
                message: None,
                is_compaction,
            }),
        }
    }

    pub fn agent_model(&self) -> Option<&str> {
        self.docs
            .get("agent")
            .and_then(Value::as_object)
            .and_then(|a| a.get("model"))
            .and_then(Value::as_str)
    }

    pub fn agent_thinking(&self) -> Option<&str> {
        self.docs
            .get("agent")
            .and_then(Value::as_object)
            .and_then(|a| a.get("thinking"))
            .and_then(Value::as_str)
    }

    pub fn usage_summary(&self) -> Option<(u64, u64, f64)> {
        let usage = self.docs.get("usage").and_then(Value::as_object)?;
        let input = usage
            .get("input_tokens")
            .or_else(|| usage.get("input"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let output = usage
            .get("output_tokens")
            .or_else(|| usage.get("output"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let total = usage
            .get("total_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(input + output);
        let cost = usage.get("cost").and_then(Value::as_f64).unwrap_or(0.0);
        if total == 0 && input == 0 && output == 0 && cost == 0.0 {
            None
        } else {
            Some((input, output, cost))
        }
    }
}

fn default_docs() -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("live".to_string(), Value::Object(Map::new()));
    map.insert("inbox".to_string(), Value::Array(Vec::new()));
    map.insert("agent".to_string(), Value::Object(Map::new()));
    map.insert("usage".to_string(), Value::Object(Map::new()));
    map
}

fn normalize_docs(docs_val: Option<Value>) -> Map<String, Value> {
    let mut base = default_docs();
    let Some(Value::Object(src)) = docs_val else {
        return base;
    };

    for (k, v) in src {
        if UNSAFE_DOC_KEYS.contains(&k.as_str()) {
            continue;
        }
        match k.as_str() {
            "live" | "agent" | "usage" => {
                if v.is_object() {
                    base.insert(k, v);
                } else {
                    base.insert(k, Value::Object(Map::new()));
                }
            }
            "inbox" => {
                if v.is_array() {
                    base.insert(k, v);
                } else {
                    base.insert(k, Value::Array(Vec::new()));
                }
            }
            _ => {
                base.insert(k, v);
            }
        }
    }
    base
}

fn normalize_entries(entries: Vec<TranscriptEntry>) -> Vec<TranscriptEntry> {
    let mut by_id: HashMap<String, TranscriptEntry> = HashMap::new();
    for entry in entries {
        if entry.id.is_empty() {
            continue;
        }
        by_id.insert(entry.id.clone(), entry);
    }
    let mut values: Vec<TranscriptEntry> = by_id.into_values().collect();
    values.sort_by(|a, b| compare_entry_ids(&a.id, &b.id));
    values
}

fn compare_entry_ids(a: &str, b: &str) -> Ordering {
    match (a.parse::<u64>(), b.parse::<u64>()) {
        (Ok(na), Ok(nb)) => na.cmp(&nb),
        (Ok(_), Err(_)) => Ordering::Less,
        (Err(_), Ok(_)) => Ordering::Greater,
        (Err(_), Err(_)) => a.cmp(b),
    }
}

fn apply_doc_ops_map(docs: &mut Map<String, Value>, doc_ops: &Map<String, Value>) {
    for (doc_name, ops_val) in doc_ops {
        if UNSAFE_DOC_KEYS.contains(&doc_name.as_str()) {
            continue;
        }
        let Some(ops) = ops_val.as_array() else {
            continue;
        };
        if ops.is_empty() {
            continue;
        }
        let current = docs.get(doc_name).cloned().unwrap_or(Value::Null);
        let updated = apply_doc_ops(current, ops);
        docs.insert(doc_name.clone(), updated);
    }
}

pub fn apply_doc_ops(mut doc: Value, ops: &[Value]) -> Value {
    for op in ops {
        let Some(arr) = op.as_array() else {
            continue;
        };
        let Some(kind) = arr.first().and_then(Value::as_str) else {
            continue;
        };
        match kind {
            "replace" | "r" => {
                if let Some(val) = arr.get(1) {
                    doc = val.clone();
                }
            }
            "set" => {
                if let (Some(path_val), Some(val)) = (arr.get(1), arr.get(2)) {
                    if let Some(path) = path_val.as_array() {
                        doc = set_at_path(doc, path, val.clone());
                    }
                }
            }
            "append_text" => {
                if let Some(path_val) = arr.get(1) {
                    if let Some(path) = path_val.as_array() {
                        let delta = match arr.get(2) {
                            None | Some(Value::Null) => String::new(),
                            Some(Value::String(s)) => s.clone(),
                            Some(other) => other.to_string(),
                        };
                        let prev = get_at_path(&doc, path)
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        let mut next = String::with_capacity(prev.len() + delta.len());
                        next.push_str(prev);
                        next.push_str(&delta);
                        doc = set_at_path(doc, path, Value::String(next));
                    }
                }
            }
            "delete" => {
                if let Some(path_val) = arr.get(1) {
                    if let Some(path) = path_val.as_array() {
                        doc = delete_at_path(doc, path);
                    }
                }
            }
            _ => {}
        }
    }
    doc
}

fn parse_path_index(seg: &Value) -> Option<usize> {
    match seg {
        Value::Number(n) => n.as_u64().and_then(|u| usize::try_from(u).ok()),
        Value::String(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
            s.parse::<usize>().ok()
        }
        _ => None,
    }
}

fn segment_key(seg: &Value) -> Option<String> {
    let key = match seg {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => return None,
    };
    if UNSAFE_DOC_KEYS.contains(&key.as_str()) {
        None
    } else {
        Some(key)
    }
}

fn get_at_path<'a>(mut cursor: &'a Value, path: &[Value]) -> Option<&'a Value> {
    for seg in path {
        match cursor {
            Value::Array(arr) => {
                let idx = parse_path_index(seg)?;
                cursor = arr.get(idx)?;
            }
            Value::Object(map) => {
                let key = segment_key(seg)?;
                cursor = map.get(&key)?;
            }
            _ => return None,
        }
    }
    Some(cursor)
}

fn set_at_path(root: Value, path: &[Value], value: Value) -> Value {
    if path.is_empty() {
        return value;
    }
    let head = &path[0];
    let tail = &path[1..];

    if let Value::Array(mut arr) = root {
        if let Some(idx) = parse_path_index(head) {
            if idx >= arr.len() {
                arr.resize(idx + 1, Value::Null);
            }
            let existing = std::mem::replace(&mut arr[idx], Value::Null);
            arr[idx] = set_at_path(existing, tail, value);
            return Value::Array(arr);
        }
        return set_at_path(Value::Object(Map::new()), path, value);
    }

    let Some(key) = segment_key(head) else {
        return root;
    };

    let mut map = match root {
        Value::Object(m) => m,
        _ => Map::new(),
    };
    let existing = map.remove(&key).unwrap_or(Value::Null);
    map.insert(key, set_at_path(existing, tail, value));
    Value::Object(map)
}

fn delete_at_path(root: Value, path: &[Value]) -> Value {
    if path.is_empty() {
        return root;
    }
    let head = &path[0];
    let tail = &path[1..];

    match root {
        Value::Array(mut arr) => {
            if let Some(idx) = parse_path_index(head) {
                if idx < arr.len() {
                    if tail.is_empty() {
                        arr.remove(idx);
                    } else {
                        let existing = std::mem::replace(&mut arr[idx], Value::Null);
                        arr[idx] = delete_at_path(existing, tail);
                    }
                }
            }
            Value::Array(arr)
        }
        Value::Object(mut map) => {
            if let Some(key) = segment_key(head) {
                if tail.is_empty() {
                    map.remove(&key);
                } else if let Some(existing) = map.remove(&key) {
                    map.insert(key, delete_at_path(existing, tail));
                }
            }
            Value::Object(map)
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn make_entry(id: &str, kind: &str, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            id: id.to_string(),
            conversation_id: Some("1".to_string()),
            seq: None,
            kind: kind.to_string(),
            data: json!({"text": text}),
            created_at: None,
        }
    }

    #[test]
    fn snapshot_dedups_sorts_and_sets_docs() {
        let mut t = TranscriptState::default();
        let snap = SnapshotFrame {
            version: Some(1),
            session_id: Some("demo".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 10,
            before_entry_id: Some("8".to_string()),
            has_more: None,
            entries: vec![
                make_entry("10", "assistant", "hi"),
                make_entry("9", "user", "stale"),
                make_entry("9", "user", "yo"),
            ],
            docs: Some(json!({
                "live": {"run": {"turns": 1}},
                "inbox": [],
                "agent": {"model": "m1"},
                "usage": {"total_tokens": 5}
            })),
        };

        t.apply_snapshot(snap);
        assert_eq!(t.seq, Some(10));
        assert_eq!(t.before_entry_id.as_deref(), Some("8"));
        assert!(t.has_more);
        assert_eq!(
            t.entries.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            vec!["9", "10"]
        );
        assert_eq!(t.entries[0].data["text"], "yo");
        assert_eq!(t.committed_docs["agent"]["model"], "m1");
        assert_eq!(t.docs, t.committed_docs);
    }

    #[test]
    fn commit_prefers_prev_seq_and_falls_back_to_sequential() {
        let mut t = TranscriptState::default();

        // Commit before snapshot => Gap
        let pre_snap = CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(0),
            seq: 1,
            appended_entries: vec![],
            doc_ops: None,
        };
        assert_eq!(t.apply_commit(pre_snap), CommitOutcome::Gap);

        t.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 10,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![make_entry("10", "user", "q")],
            docs: None,
        });

        // Stale commit (seq <= 10)
        assert_eq!(
            t.apply_commit(CommitFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                prev_seq: Some(9),
                seq: 10,
                appended_entries: vec![],
                doc_ops: None,
            }),
            CommitOutcome::Stale
        );

        // prev_seq == 10 allows jumping seq 10 -> 13 (e.g. another conv committed 11, 12)
        let outcome = t.apply_commit(CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(10),
            seq: 13,
            appended_entries: vec![make_entry("11", "assistant", "a")],
            doc_ops: None,
        });
        assert!(matches!(outcome, CommitOutcome::Applied { .. }));
        assert_eq!(t.seq, Some(13));

        // prev_seq mismatch => Gap
        assert_eq!(
            t.apply_commit(CommitFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                prev_seq: Some(12),
                seq: 14,
                appended_entries: vec![],
                doc_ops: None,
            }),
            CommitOutcome::Gap
        );

        // Without prev_seq, seq > cur + 1 => Gap; seq == cur + 1 => Applied
        assert_eq!(
            t.apply_commit(CommitFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                prev_seq: None,
                seq: 15,
                appended_entries: vec![],
                doc_ops: None,
            }),
            CommitOutcome::Gap
        );

        let seq_ok = t.apply_commit(CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: None,
            seq: 14,
            appended_entries: vec![make_entry("12", "user", "q2")],
            doc_ops: None,
        });
        assert!(matches!(seq_ok, CommitOutcome::Applied { .. }));
        assert_eq!(t.seq, Some(14));
    }

    #[test]
    fn ephemeral_fences_on_base_seq_and_commit_resets_live() {
        let mut t = TranscriptState::default();
        t.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 5,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![],
            docs: Some(json!({"live": {"run": {"turns": 1}}})),
        });

        // Wrong base_seq ignored
        assert_eq!(
            t.apply_ephemeral(EphemeralFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                base_seq: 4,
                doc_ops: Some(
                    json!({"live": [["append_text", ["generation", "message", "text"], "NO"]]})
                        .as_object()
                        .unwrap()
                        .clone()
                ),
                ops: None,
            }),
            EphemeralOutcome::Ignored
        );

        // Matching base_seq updates docs["live"] only
        assert_eq!(
            t.apply_ephemeral(EphemeralFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                base_seq: 5,
                doc_ops: Some(
                    json!({"live": [["append_text", ["generation", "message", "text"], "Hel"]]})
                        .as_object()
                        .unwrap()
                        .clone()
                ),
                ops: None,
            }),
            EphemeralOutcome::Applied
        );
        assert_eq!(
            t.apply_ephemeral(EphemeralFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                base_seq: 5,
                doc_ops: None,
                ops: Some(vec![json!([
                    "append_text",
                    ["generation", "message", "text"],
                    "lo"
                ])]),
            }),
            EphemeralOutcome::Applied
        );

        assert_eq!(t.docs["live"]["generation"]["message"]["text"], "Hello");
        assert!(t.committed_docs["live"]["generation"].is_null());

        // Commit replaces live and clears stale ephemeral generation
        let res = t.apply_commit(CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(5),
            seq: 6,
            appended_entries: vec![make_entry("1", "assistant", "Hello")],
            doc_ops: Some(
                json!({"live": [["replace", {}]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        });
        assert!(matches!(res, CommitOutcome::Applied { .. }));
        assert_eq!(t.docs, t.committed_docs);
        assert!(t.docs["live"]["generation"].is_null());
        assert!(!t.is_run_active());
    }

    #[test]
    fn prepend_older_page_dedups_and_updates_cursor() {
        let mut t = TranscriptState::default();
        t.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 10,
            before_entry_id: Some("8".to_string()),
            has_more: None,
            entries: vec![
                make_entry("9", "user", "a"),
                make_entry("10", "assistant", "b"),
            ],
            docs: None,
        });

        let added = t.prepend_older_page(
            vec![
                make_entry("9", "user", "dup"),
                make_entry("8", "assistant", "old1"),
                make_entry("7", "user", "old0"),
            ],
            Some("6".to_string()),
        );
        assert_eq!(added, 2);
        assert_eq!(
            t.entries.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            vec!["7", "8", "9", "10"]
        );
        assert_eq!(t.before_entry_id.as_deref(), Some("6"));
        assert!(t.has_more);
    }
}
