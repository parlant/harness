//! Interactive session-wide turn-step tree selector (`/tree`).
//!
//! Renders turn steps across all conversations/branches in a session with
//! `pi`-style smart indentation (flat single-child chains, branch-point
//! connectors `├─ ` / `└─ ` / `│  `, active-path `• ` markers, conversation
//! head badges, filter modes, incremental search, and branch folding).

use crate::protocol::{ConversationInfo, SessionTreeResponse, TreeNode};
use crate::render::sanitize_single_line;
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use std::collections::{HashMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;

const DEFAULT_MAX_VISIBLE: usize = 12;

/// Filter mode controlling which turn steps are displayed in the tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterMode {
    Default,
    NoTools,
    UserOnly,
    All,
}

impl FilterMode {
    pub fn next(self) -> Self {
        match self {
            Self::Default => Self::NoTools,
            Self::NoTools => Self::UserOnly,
            Self::UserOnly => Self::All,
            Self::All => Self::Default,
        }
    }

    pub fn prev(self) -> Self {
        match self {
            Self::Default => Self::All,
            Self::NoTools => Self::Default,
            Self::UserOnly => Self::NoTools,
            Self::All => Self::UserOnly,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::NoTools => "no-tools",
            Self::UserOnly => "user-only",
            Self::All => "all",
        }
    }
}

/// Selected step payload returned when the user presses `Enter` on a tree node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeSelection {
    pub node: TreeNode,
    /// Conversation IDs whose `leaf_entry_id` points directly at `node.id`.
    pub leaf_conversations: Vec<String>,
    /// Empty fork conversations (`parent.at == node.id` and `leaf_entry_id == node.id`).
    pub empty_fork_conversations: Vec<String>,
    /// Whether `node` has any child nodes in the full session tree.
    pub has_children: bool,
}

/// Outcome of handling a key event inside [`TreeSelector`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TreeChoice {
    Stay,
    Cancel,
    Select(Box<TreeSelection>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct GutterInfo {
    position: usize,
    show: bool,
}

#[derive(Debug, Clone)]
struct FlatNode {
    node_idx: usize,
    indent: usize,
    show_connector: bool,
    is_last: bool,
    gutters: Vec<GutterInfo>,
    is_virtual_root_child: bool,
}

/// Interactive turn-step tree selector for `/tree`.
#[derive(Debug, Clone)]
pub struct TreeSelector {
    nodes: Vec<TreeNode>,
    conversations: Vec<ConversationInfo>,
    current_cid: String,
    current_leaf_id: Option<String>,
    truncated: bool,

    // Full-tree indices and precomputed metadata
    full_parent_map: HashMap<String, Option<String>>,
    full_children_count: HashMap<String, usize>,
    leaf_convs_by_entry: HashMap<String, Vec<String>>,
    empty_forks_by_entry: HashMap<String, Vec<String>>,
    active_path_ids: HashSet<String>,

    // Flattened and filtered views
    flat_nodes: Vec<FlatNode>,
    filtered_nodes: Vec<FlatNode>,
    visible_parent_map: HashMap<String, Option<String>>,
    visible_children_map: HashMap<Option<String>, Vec<String>>,
    multiple_roots: bool,

    // Interactive state
    filter_mode: FilterMode,
    search_query: String,
    cursor: usize,
    folded_nodes: HashSet<String>,
    selected_index: usize,
    last_selected_id: Option<String>,
    max_visible: usize,
}

impl TreeSelector {
    pub fn new(tree: SessionTreeResponse, current_cid: &str) -> Self {
        let current_cid = current_cid.to_string();
        let current_leaf_id = resolve_current_leaf_id(&tree.conversations, &current_cid);

        let mut id_to_node_idx = HashMap::with_capacity(tree.nodes.len());
        for (idx, node) in tree.nodes.iter().enumerate() {
            id_to_node_idx.insert(node.id.clone(), idx);
        }

        // Normalize parent pointers: missing parents (e.g. truncated) or self-cycles become roots.
        let mut full_parent_map = HashMap::with_capacity(tree.nodes.len());
        let mut children_by_parent: HashMap<Option<String>, Vec<usize>> = HashMap::new();
        children_by_parent.insert(None, Vec::new());

        for (idx, node) in tree.nodes.iter().enumerate() {
            let valid_parent = node
                .parent_id
                .as_ref()
                .filter(|pid| *pid != &node.id && id_to_node_idx.contains_key(*pid))
                .cloned();
            full_parent_map.insert(node.id.clone(), valid_parent.clone());
            children_by_parent
                .entry(valid_parent)
                .or_default()
                .push(idx);
        }

        let mut full_children_count = HashMap::with_capacity(tree.nodes.len());
        for (parent_opt, kids) in &children_by_parent {
            if let Some(pid) = parent_opt {
                full_children_count.insert(pid.clone(), kids.len());
            }
        }

        // Map leaf_entry_id -> conversation IDs (put current_cid first when present)
        let mut leaf_convs_by_entry: HashMap<String, Vec<String>> = HashMap::new();
        let mut empty_forks_by_entry: HashMap<String, Vec<String>> = HashMap::new();
        for conv in &tree.conversations {
            let eff_leaf = conv
                .leaf_entry_id
                .clone()
                .or_else(|| conv.parent.as_ref().map(|p| p.at.clone()));
            if let Some(leaf_id) = eff_leaf {
                leaf_convs_by_entry
                    .entry(leaf_id.clone())
                    .or_default()
                    .push(conv.id.clone());
                if conv.parent.as_ref().is_some_and(|p| p.at == leaf_id) {
                    empty_forks_by_entry
                        .entry(leaf_id)
                        .or_default()
                        .push(conv.id.clone());
                }
            }
        }
        for cids in leaf_convs_by_entry.values_mut() {
            cids.sort_by(|a, b| {
                let a_cur = a == &current_cid;
                let b_cur = b == &current_cid;
                b_cur.cmp(&a_cur).then_with(|| cmp_id_str(a, b))
            });
            cids.dedup();
        }
        for cids in empty_forks_by_entry.values_mut() {
            cids.sort_by(|a, b| cmp_id_str(a, b));
            cids.dedup();
        }

        let active_path_ids = build_active_path(&current_leaf_id, &full_parent_map);

        let mut selector = Self {
            nodes: tree.nodes,
            conversations: tree.conversations,
            current_cid,
            current_leaf_id,
            truncated: tree.truncated,
            full_parent_map,
            full_children_count,
            leaf_convs_by_entry,
            empty_forks_by_entry,
            active_path_ids,
            flat_nodes: Vec::new(),
            filtered_nodes: Vec::new(),
            visible_parent_map: HashMap::new(),
            visible_children_map: HashMap::new(),
            multiple_roots: false,
            filter_mode: FilterMode::Default,
            search_query: String::new(),
            cursor: 0,
            folded_nodes: HashSet::new(),
            selected_index: 0,
            last_selected_id: None,
            max_visible: DEFAULT_MAX_VISIBLE,
        };

        selector.flat_nodes = selector.flatten_tree(&children_by_parent);
        selector.apply_filter();

        let initial_target = selector.current_leaf_id.clone();
        selector.selected_index = selector.find_nearest_visible_index(initial_target.as_deref());
        selector.last_selected_id = selector
            .filtered_nodes
            .get(selector.selected_index)
            .map(|f| selector.nodes[f.node_idx].id.clone());

        selector
    }

    pub fn set_max_visible(&mut self, max_visible: usize) {
        self.max_visible = max_visible.clamp(1, 24);
    }

    pub fn filter_mode(&self) -> FilterMode {
        self.filter_mode
    }

    pub fn search_query(&self) -> &str {
        &self.search_query
    }

    pub fn current_leaf_id(&self) -> Option<&str> {
        self.current_leaf_id.as_deref()
    }

    pub fn filtered_len(&self) -> usize {
        self.filtered_nodes.len()
    }

    pub fn total_len(&self) -> usize {
        self.nodes.len()
    }

    pub fn selected_node(&self) -> Option<&TreeNode> {
        self.filtered_nodes
            .get(self.selected_index)
            .map(|f| &self.nodes[f.node_idx])
    }

    pub fn is_folded(&self, entry_id: &str) -> bool {
        self.folded_nodes.contains(entry_id)
    }

    pub fn conversation_count(&self) -> usize {
        self.conversations.len()
    }

    /// Renders sanitized, ANSI-free overlay lines: header, visible tree rows, and footer.
    pub fn lines(&self) -> Vec<String> {
        let mut out = Vec::new();
        let trunc = if self.truncated { " · truncated" } else { "" };
        let clean_query = sanitize_single_line(&self.search_query);
        let search_part = if clean_query.is_empty() {
            String::new()
        } else {
            format!(" · Search: {clean_query}")
        };
        out.push(format!(
            "Tree [{}] · #{} ({} branches{trunc}){search_part}",
            self.filter_mode.label(),
            sanitize_single_line(&self.current_cid),
            self.conversations.len(),
        ));

        if self.filtered_nodes.is_empty() {
            out.push("  (no matching steps)".to_string());
            out.push(format!(
                "  (0/{}) · Tab/Ctrl-O filter · type to search · Esc close",
                self.nodes.len()
            ));
            return out;
        }

        let (start, end) = self.visible_range();
        for (offset, flat) in self.filtered_nodes[start..end].iter().enumerate() {
            let actual_pos = start + offset;
            let is_selected = actual_pos == self.selected_index;
            out.push(self.format_row(flat, is_selected));
        }

        out.push(format!(
            "  ({}/{}) · Enter select · Tab/Ctrl-O filter · ←/→ fold · Esc {}",
            self.selected_index + 1,
            self.filtered_nodes.len(),
            if self.search_query.is_empty() {
                "close"
            } else {
                "clear search"
            }
        ));

        out
    }

    pub fn key(&mut self, key: KeyEvent) -> TreeChoice {
        if key.kind == KeyEventKind::Release {
            return TreeChoice::Stay;
        }

        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        let sup = key.modifiers.contains(KeyModifiers::SUPER);

        match key.code {
            KeyCode::Esc => {
                if !self.search_query.is_empty() {
                    self.search_query.clear();
                    self.cursor = 0;
                    self.folded_nodes.clear();
                    self.apply_filter();
                    TreeChoice::Stay
                } else {
                    TreeChoice::Cancel
                }
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'c') => {
                TreeChoice::Cancel
            }
            KeyCode::Enter if !alt && !ctrl && !sup => self.confirm_selection(),

            // Vertical navigation
            KeyCode::Up if !alt && !ctrl && !sup => {
                self.move_up();
                TreeChoice::Stay
            }
            KeyCode::Down if !alt && !ctrl && !sup => {
                self.move_down();
                TreeChoice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'p') => {
                self.move_up();
                TreeChoice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'n') => {
                self.move_down();
                TreeChoice::Stay
            }
            KeyCode::PageUp if !alt && !ctrl && !sup => {
                self.page_up();
                TreeChoice::Stay
            }
            KeyCode::PageDown if !alt && !ctrl && !sup => {
                self.page_down();
                TreeChoice::Stay
            }

            // Filter cycling: Tab / Shift-Tab / BackTab / Ctrl-O / Alt-F
            KeyCode::Tab if !ctrl && !alt && !sup => {
                self.filter_mode = if shift {
                    self.filter_mode.prev()
                } else {
                    self.filter_mode.next()
                };
                self.folded_nodes.clear();
                self.apply_filter();
                TreeChoice::Stay
            }
            KeyCode::BackTab if !ctrl && !alt && !sup => {
                self.filter_mode = self.filter_mode.prev();
                self.folded_nodes.clear();
                self.apply_filter();
                TreeChoice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'o') => {
                self.filter_mode = self.filter_mode.next();
                self.folded_nodes.clear();
                self.apply_filter();
                TreeChoice::Stay
            }
            KeyCode::Char(c) if alt && !ctrl && !sup && c.eq_ignore_ascii_case(&'f') => {
                self.filter_mode = self.filter_mode.next();
                self.folded_nodes.clear();
                self.apply_filter();
                TreeChoice::Stay
            }

            // Folding / branch-segment jumps:
            // Left/Right when search query is empty, or Alt-Left/Right / Ctrl-Left/Right anytime.
            KeyCode::Left if (alt || ctrl) && !sup => {
                self.fold_or_jump_up();
                TreeChoice::Stay
            }
            KeyCode::Right if (alt || ctrl) && !sup => {
                self.unfold_or_jump_down();
                TreeChoice::Stay
            }
            KeyCode::Left if !alt && !ctrl && !sup => {
                if self.search_query.is_empty() {
                    self.fold_or_jump_up();
                } else {
                    self.move_cursor_left();
                }
                TreeChoice::Stay
            }
            KeyCode::Right if !alt && !ctrl && !sup => {
                if self.search_query.is_empty() {
                    self.unfold_or_jump_down();
                } else {
                    self.move_cursor_right();
                }
                TreeChoice::Stay
            }

            // Search input editing
            KeyCode::Home if !alt && !ctrl && !sup => {
                if self.search_query.is_empty() {
                    self.selected_index = 0;
                    self.sync_last_selected();
                } else {
                    self.cursor = 0;
                }
                TreeChoice::Stay
            }
            KeyCode::End if !alt && !ctrl && !sup => {
                if self.search_query.is_empty() {
                    if !self.filtered_nodes.is_empty() {
                        self.selected_index = self.filtered_nodes.len() - 1;
                        self.sync_last_selected();
                    }
                } else {
                    self.cursor = self.search_query.len();
                }
                TreeChoice::Stay
            }
            KeyCode::Backspace if !ctrl && !sup => {
                if self.delete_char_backward() {
                    self.folded_nodes.clear();
                    self.apply_filter();
                }
                TreeChoice::Stay
            }
            KeyCode::Delete if !ctrl && !sup => {
                if self.delete_char_forward() {
                    self.folded_nodes.clear();
                    self.apply_filter();
                }
                TreeChoice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup => {
                match c.to_ascii_lowercase() {
                    'u' if !self.search_query.is_empty() => {
                        self.search_query.drain(..self.cursor);
                        self.cursor = 0;
                        self.folded_nodes.clear();
                        self.apply_filter();
                    }
                    'k' if self.cursor < self.search_query.len() => {
                        self.search_query.truncate(self.cursor);
                        self.folded_nodes.clear();
                        self.apply_filter();
                    }
                    'a' => self.cursor = 0,
                    'e' => self.cursor = self.search_query.len(),
                    _ => {}
                }
                TreeChoice::Stay
            }
            KeyCode::Char(c) if !ctrl && !alt && !sup && !c.is_control() => {
                self.insert_char(c);
                self.folded_nodes.clear();
                self.apply_filter();
                TreeChoice::Stay
            }
            _ => TreeChoice::Stay,
        }
    }

    fn confirm_selection(&self) -> TreeChoice {
        let Some(flat) = self.filtered_nodes.get(self.selected_index) else {
            return TreeChoice::Stay;
        };
        let node = self.nodes[flat.node_idx].clone();
        let leaf_conversations = self
            .leaf_convs_by_entry
            .get(&node.id)
            .cloned()
            .unwrap_or_default();
        let empty_fork_conversations = self
            .empty_forks_by_entry
            .get(&node.id)
            .cloned()
            .unwrap_or_default();
        let has_children = self.full_children_count.get(&node.id).copied().unwrap_or(0) > 0;
        TreeChoice::Select(Box::new(TreeSelection {
            node,
            leaf_conversations,
            empty_fork_conversations,
            has_children,
        }))
    }

    fn move_up(&mut self) {
        if self.filtered_nodes.is_empty() {
            return;
        }
        self.selected_index = if self.selected_index == 0 {
            self.filtered_nodes.len() - 1
        } else {
            self.selected_index - 1
        };
        self.sync_last_selected();
    }

    fn move_down(&mut self) {
        if self.filtered_nodes.is_empty() {
            return;
        }
        self.selected_index = if self.selected_index + 1 >= self.filtered_nodes.len() {
            0
        } else {
            self.selected_index + 1
        };
        self.sync_last_selected();
    }

    fn page_up(&mut self) {
        if self.filtered_nodes.is_empty() {
            return;
        }
        self.selected_index = self.selected_index.saturating_sub(self.max_visible);
        self.sync_last_selected();
    }

    fn page_down(&mut self) {
        if self.filtered_nodes.is_empty() {
            return;
        }
        self.selected_index =
            (self.selected_index + self.max_visible).min(self.filtered_nodes.len() - 1);
        self.sync_last_selected();
    }

    fn sync_last_selected(&mut self) {
        if let Some(flat) = self.filtered_nodes.get(self.selected_index) {
            self.last_selected_id = Some(self.nodes[flat.node_idx].id.clone());
        }
    }

    fn fold_or_jump_up(&mut self) {
        let Some(current_id) = self
            .filtered_nodes
            .get(self.selected_index)
            .map(|f| self.nodes[f.node_idx].id.clone())
        else {
            return;
        };
        if self.is_foldable(&current_id) && !self.folded_nodes.contains(&current_id) {
            self.folded_nodes.insert(current_id);
            self.apply_filter();
        } else {
            self.selected_index = self.find_branch_segment_start_up();
            self.sync_last_selected();
        }
    }

    fn unfold_or_jump_down(&mut self) {
        let Some(current_id) = self
            .filtered_nodes
            .get(self.selected_index)
            .map(|f| self.nodes[f.node_idx].id.clone())
        else {
            return;
        };
        if self.folded_nodes.remove(&current_id) {
            self.apply_filter();
        } else {
            self.selected_index = self.find_branch_segment_start_down();
            self.sync_last_selected();
        }
    }

    fn is_foldable(&self, entry_id: &str) -> bool {
        let has_vis_children = self
            .visible_children_map
            .get(&Some(entry_id.to_string()))
            .is_some_and(|kids| !kids.is_empty());
        if !has_vis_children {
            return false;
        }
        let parent_id = self.visible_parent_map.get(entry_id).cloned().flatten();
        match parent_id {
            None => true,
            Some(pid) => self
                .visible_children_map
                .get(&Some(pid))
                .is_some_and(|siblings| siblings.len() > 1),
        }
    }

    fn find_branch_segment_start_down(&self) -> usize {
        let Some(selected_id) = self
            .filtered_nodes
            .get(self.selected_index)
            .map(|f| self.nodes[f.node_idx].id.clone())
        else {
            return self.selected_index;
        };
        let index_by_id: HashMap<&str, usize> = self
            .filtered_nodes
            .iter()
            .enumerate()
            .map(|(i, f)| (self.nodes[f.node_idx].id.as_str(), i))
            .collect();

        let mut current = selected_id;
        loop {
            let kids = self
                .visible_children_map
                .get(&Some(current.clone()))
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if kids.is_empty() {
                return index_by_id
                    .get(current.as_str())
                    .copied()
                    .unwrap_or(self.selected_index);
            }
            if kids.len() > 1 {
                return index_by_id
                    .get(kids[0].as_str())
                    .copied()
                    .unwrap_or(self.selected_index);
            }
            current = kids[0].clone();
        }
    }

    fn find_branch_segment_start_up(&self) -> usize {
        let Some(selected_id) = self
            .filtered_nodes
            .get(self.selected_index)
            .map(|f| self.nodes[f.node_idx].id.clone())
        else {
            return self.selected_index;
        };
        let index_by_id: HashMap<&str, usize> = self
            .filtered_nodes
            .iter()
            .enumerate()
            .map(|(i, f)| (self.nodes[f.node_idx].id.as_str(), i))
            .collect();

        let mut current = selected_id;
        loop {
            let parent_opt = self.visible_parent_map.get(&current).cloned().flatten();
            let Some(parent_id) = parent_opt else {
                return index_by_id
                    .get(current.as_str())
                    .copied()
                    .unwrap_or(self.selected_index);
            };
            let siblings = self
                .visible_children_map
                .get(&Some(parent_id.clone()))
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if siblings.len() > 1 {
                if let Some(&seg_idx) = index_by_id.get(current.as_str()) {
                    if seg_idx < self.selected_index {
                        return seg_idx;
                    }
                }
            }
            current = parent_id;
        }
    }

    fn visible_range(&self) -> (usize, usize) {
        let len = self.filtered_nodes.len();
        if len <= self.max_visible {
            return (0, len);
        }
        let half = self.max_visible / 2;
        let start = self
            .selected_index
            .saturating_sub(half)
            .min(len.saturating_sub(self.max_visible));
        let end = (start + self.max_visible).min(len);
        (start, end)
    }

    fn format_row(&self, flat: &FlatNode, is_selected: bool) -> String {
        let node = &self.nodes[flat.node_idx];
        let cursor = if is_selected { "> " } else { "  " };
        let display_indent = if self.multiple_roots {
            flat.indent.saturating_sub(1)
        } else {
            flat.indent
        };

        let show_connector = flat.show_connector && !flat.is_virtual_root_child;
        let connector_pos = if show_connector {
            display_indent.checked_sub(1)
        } else {
            None
        };
        let is_folded = self.folded_nodes.contains(&node.id);
        let foldable = self.is_foldable(&node.id);

        let mut prefix = String::with_capacity(display_indent * 3 + 4);
        for level in 0..display_indent {
            if let Some(gutter) = flat.gutters.iter().find(|g| g.position == level) {
                prefix.push_str(if gutter.show { "│  " } else { "   " });
            } else if connector_pos == Some(level) {
                prefix.push(if flat.is_last { '└' } else { '├' });
                prefix.push(if is_folded {
                    '⊞'
                } else if foldable {
                    '⊟'
                } else {
                    '─'
                });
                prefix.push(' ');
            } else {
                prefix.push_str("   ");
            }
        }

        let root_fold_marker = if is_folded && !show_connector {
            "⊞ "
        } else {
            ""
        };
        let active_marker = if self.active_path_ids.contains(&node.id) {
            "• "
        } else {
            ""
        };

        let kind_label = format_kind_label(node);
        let preview = format_node_preview(node);
        let badges = self.format_branch_badges(&node.id);

        if preview.is_empty() {
            format!(
                "{cursor}{prefix}{root_fold_marker}{active_marker}#{} {kind_label}{badges}",
                sanitize_single_line(&node.id),
            )
        } else {
            format!(
                "{cursor}{prefix}{root_fold_marker}{active_marker}#{} {kind_label}{badges}: {preview}",
                sanitize_single_line(&node.id),
            )
        }
    }

    fn format_branch_badges(&self, entry_id: &str) -> String {
        let Some(cids) = self.leaf_convs_by_entry.get(entry_id) else {
            return String::new();
        };
        if cids.is_empty() {
            return String::new();
        }
        let mut out = String::new();
        for cid in cids {
            let clean = sanitize_single_line(cid);
            if cid == &self.current_cid {
                out.push_str(&format!(" [#{clean} *]"));
            } else {
                out.push_str(&format!(" [#{clean}]"));
            }
        }
        out
    }

    fn flatten_tree(
        &self,
        children_by_parent: &HashMap<Option<String>, Vec<usize>>,
    ) -> Vec<FlatNode> {
        let roots = children_by_parent.get(&None).cloned().unwrap_or_default();
        if roots.is_empty() {
            return Vec::new();
        }

        // Compute contains_active via iterative post-order traversal.
        let mut contains_active = vec![false; self.nodes.len()];
        let mut pre_order = Vec::with_capacity(self.nodes.len());
        let mut walk_stack: Vec<usize> = roots.iter().rev().copied().collect();
        while let Some(idx) = walk_stack.pop() {
            pre_order.push(idx);
            if let Some(kids) = children_by_parent.get(&Some(self.nodes[idx].id.clone())) {
                for &kid in kids.iter().rev() {
                    walk_stack.push(kid);
                }
            }
        }
        for &idx in pre_order.iter().rev() {
            let mut has = self
                .current_leaf_id
                .as_deref()
                .is_some_and(|leaf| leaf == self.nodes[idx].id);
            if let Some(kids) = children_by_parent.get(&Some(self.nodes[idx].id.clone())) {
                for &kid in kids {
                    if contains_active[kid] {
                        has = true;
                    }
                }
            }
            contains_active[idx] = has;
        }

        let multiple_roots = roots.len() > 1;
        let ordered_roots = prioritize_active(&roots, &contains_active);

        // Stack items: (node_idx, indent, just_branched, show_connector, is_last, gutters, is_virtual_root_child)
        type StackItem = (usize, usize, bool, bool, bool, Vec<GutterInfo>, bool);
        let mut stack: Vec<StackItem> = Vec::with_capacity(self.nodes.len());
        for (i, &root_idx) in ordered_roots.iter().enumerate().rev() {
            let is_last = i + 1 == ordered_roots.len();
            stack.push((
                root_idx,
                usize::from(multiple_roots),
                multiple_roots,
                multiple_roots,
                is_last,
                Vec::new(),
                multiple_roots,
            ));
        }

        let mut result = Vec::with_capacity(self.nodes.len());
        while let Some((
            node_idx,
            indent,
            just_branched,
            show_connector,
            is_last,
            gutters,
            is_virtual_root_child,
        )) = stack.pop()
        {
            result.push(FlatNode {
                node_idx,
                indent,
                show_connector,
                is_last,
                gutters: gutters.clone(),
                is_virtual_root_child,
            });

            let kids = children_by_parent
                .get(&Some(self.nodes[node_idx].id.clone()))
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if kids.is_empty() {
                continue;
            }
            let multiple_children = kids.len() > 1;
            let ordered_kids = prioritize_active(kids, &contains_active);

            let child_indent = if multiple_children || (just_branched && indent > 0) {
                indent + 1
            } else {
                indent
            };

            let connector_displayed = show_connector && !is_virtual_root_child;
            let current_display_indent = if multiple_roots {
                indent.saturating_sub(1)
            } else {
                indent
            };
            let connector_position = current_display_indent.saturating_sub(1);
            let mut child_gutters = gutters;
            if connector_displayed {
                child_gutters.push(GutterInfo {
                    position: connector_position,
                    show: !is_last,
                });
            }

            for (i, &kid_idx) in ordered_kids.iter().enumerate().rev() {
                let child_is_last = i + 1 == ordered_kids.len();
                stack.push((
                    kid_idx,
                    child_indent,
                    multiple_children,
                    multiple_children,
                    child_is_last,
                    child_gutters.clone(),
                    false,
                ));
            }
        }

        result
    }

    fn apply_filter(&mut self) {
        if !self.filtered_nodes.is_empty() {
            if let Some(flat) = self.filtered_nodes.get(self.selected_index) {
                self.last_selected_id = Some(self.nodes[flat.node_idx].id.clone());
            }
        }

        let search_tokens: Vec<String> = self
            .search_query
            .split_whitespace()
            .map(|t| t.to_lowercase())
            .collect();

        let mut visible: Vec<FlatNode> = self
            .flat_nodes
            .iter()
            .filter(|flat| {
                let node = &self.nodes[flat.node_idx];
                if !self.passes_filter_mode(node) {
                    return false;
                }
                if !search_tokens.is_empty() {
                    let hay = self.searchable_text(node);
                    return search_tokens.iter().all(|tok| hay.contains(tok));
                }
                true
            })
            .cloned()
            .collect();

        // Hide descendants of folded nodes (walking full tree order guarantees parents precede children).
        if !self.folded_nodes.is_empty() {
            let mut skip_set: HashSet<&str> = HashSet::new();
            for flat in &self.flat_nodes {
                let node = &self.nodes[flat.node_idx];
                if let Some(pid) = self
                    .full_parent_map
                    .get(&node.id)
                    .and_then(Option::as_deref)
                {
                    if self.folded_nodes.contains(pid) || skip_set.contains(pid) {
                        skip_set.insert(node.id.as_str());
                    }
                }
            }
            visible.retain(|flat| !skip_set.contains(self.nodes[flat.node_idx].id.as_str()));
        }

        self.filtered_nodes = visible;
        self.recalculate_visual_structure();

        if let Some(ref prev_id) = self.last_selected_id {
            self.selected_index = self.find_nearest_visible_index(Some(prev_id.as_str()));
        } else if self.selected_index >= self.filtered_nodes.len() {
            self.selected_index = self.filtered_nodes.len().saturating_sub(1);
        }

        self.sync_last_selected();
    }

    fn passes_filter_mode(&self, node: &TreeNode) -> bool {
        let is_current_leaf = self
            .current_leaf_id
            .as_deref()
            .is_some_and(|leaf| leaf == node.id);
        let has_branch_badge = self
            .leaf_convs_by_entry
            .get(&node.id)
            .is_some_and(|cids| !cids.is_empty());

        let is_tool_only_assistant = node.kind == "assistant"
            && !node.has_text
            && !node.aborted
            && !node.error
            && !node.is_error;

        match self.filter_mode {
            FilterMode::All => true,
            FilterMode::UserOnly => node.kind == "user",
            FilterMode::NoTools => {
                node.kind != "tool_result"
                    && !(is_tool_only_assistant && !is_current_leaf && !has_branch_badge)
            }
            FilterMode::Default => {
                !(is_tool_only_assistant && !is_current_leaf && !has_branch_badge)
            }
        }
    }

    fn searchable_text(&self, node: &TreeNode) -> String {
        let mut parts = Vec::with_capacity(6);
        parts.push(format!("#{}", node.id));
        parts.push(node.kind.clone());
        parts.push(node.preview.clone());
        if let Some(ref tool) = node.tool_name {
            parts.push(tool.clone());
        }
        parts.push(format!("#{}", node.conversation_id));
        if let Some(cids) = self.leaf_convs_by_entry.get(&node.id) {
            for cid in cids {
                parts.push(format!("#{cid}"));
            }
        }
        parts.join(" ").to_lowercase()
    }

    fn recalculate_visual_structure(&mut self) {
        self.visible_parent_map.clear();
        self.visible_children_map.clear();
        self.visible_children_map.insert(None, Vec::new());

        if self.filtered_nodes.is_empty() {
            self.multiple_roots = false;
            return;
        }

        let visible_ids: HashSet<&str> = self
            .filtered_nodes
            .iter()
            .map(|f| self.nodes[f.node_idx].id.as_str())
            .collect();

        for flat in &self.filtered_nodes {
            let node_id = &self.nodes[flat.node_idx].id;
            let mut cur = self.full_parent_map.get(node_id).and_then(Option::as_deref);
            let mut ancestor: Option<String> = None;
            while let Some(pid) = cur {
                if visible_ids.contains(pid) {
                    ancestor = Some(pid.to_string());
                    break;
                }
                cur = self.full_parent_map.get(pid).and_then(Option::as_deref);
            }
            self.visible_parent_map
                .insert(node_id.clone(), ancestor.clone());
            self.visible_children_map
                .entry(ancestor)
                .or_default()
                .push(node_id.clone());
        }

        let visible_roots = self
            .visible_children_map
            .get(&None)
            .cloned()
            .unwrap_or_default();
        self.multiple_roots = visible_roots.len() > 1;

        let id_to_filtered_pos: HashMap<String, usize> = self
            .filtered_nodes
            .iter()
            .enumerate()
            .map(|(i, f)| (self.nodes[f.node_idx].id.clone(), i))
            .collect();

        type StackItem = (String, usize, bool, bool, bool, Vec<GutterInfo>, bool);
        let mut stack: Vec<StackItem> = Vec::with_capacity(self.filtered_nodes.len());
        for (i, root_id) in visible_roots.iter().enumerate().rev() {
            let is_last = i + 1 == visible_roots.len();
            stack.push((
                root_id.clone(),
                usize::from(self.multiple_roots),
                self.multiple_roots,
                self.multiple_roots,
                is_last,
                Vec::new(),
                self.multiple_roots,
            ));
        }

        while let Some((
            node_id,
            indent,
            just_branched,
            show_connector,
            is_last,
            gutters,
            is_virtual_root_child,
        )) = stack.pop()
        {
            if let Some(&pos) = id_to_filtered_pos.get(&node_id) {
                let flat = &mut self.filtered_nodes[pos];
                flat.indent = indent;
                flat.show_connector = show_connector;
                flat.is_last = is_last;
                flat.gutters = gutters.clone();
                flat.is_virtual_root_child = is_virtual_root_child;
            }

            let kids = self
                .visible_children_map
                .get(&Some(node_id))
                .cloned()
                .unwrap_or_default();
            if kids.is_empty() {
                continue;
            }
            let multiple_children = kids.len() > 1;
            let child_indent = if multiple_children || (just_branched && indent > 0) {
                indent + 1
            } else {
                indent
            };

            let connector_displayed = show_connector && !is_virtual_root_child;
            let current_display_indent = if self.multiple_roots {
                indent.saturating_sub(1)
            } else {
                indent
            };
            let connector_position = current_display_indent.saturating_sub(1);
            let mut child_gutters = gutters;
            if connector_displayed {
                child_gutters.push(GutterInfo {
                    position: connector_position,
                    show: !is_last,
                });
            }

            for (i, kid_id) in kids.iter().enumerate().rev() {
                let child_is_last = i + 1 == kids.len();
                stack.push((
                    kid_id.clone(),
                    child_indent,
                    multiple_children,
                    multiple_children,
                    child_is_last,
                    child_gutters.clone(),
                    false,
                ));
            }
        }
    }

    fn find_nearest_visible_index(&self, entry_id: Option<&str>) -> usize {
        if self.filtered_nodes.is_empty() {
            return 0;
        }
        let visible_pos: HashMap<&str, usize> = self
            .filtered_nodes
            .iter()
            .enumerate()
            .map(|(i, f)| (self.nodes[f.node_idx].id.as_str(), i))
            .collect();

        let mut cur = entry_id;
        let mut guard = 0usize;
        while let Some(id) = cur {
            if let Some(&pos) = visible_pos.get(id) {
                return pos;
            }
            guard += 1;
            if guard > self.nodes.len() + 1 {
                break;
            }
            cur = self.full_parent_map.get(id).and_then(Option::as_deref);
        }

        self.filtered_nodes.len() - 1
    }

    fn insert_char(&mut self, ch: char) {
        self.search_query.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
    }

    fn move_cursor_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.search_query[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(idx, _)| idx);
    }

    fn move_cursor_right(&mut self) {
        if self.cursor >= self.search_query.len() {
            return;
        }
        if let Some((_, g)) = self.search_query[self.cursor..]
            .grapheme_indices(true)
            .next()
        {
            self.cursor += g.len();
        }
    }

    fn delete_char_backward(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        let prev = self.search_query[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(idx, _)| idx);
        self.search_query.drain(prev..self.cursor);
        self.cursor = prev;
        true
    }

    fn delete_char_forward(&mut self) -> bool {
        if self.cursor >= self.search_query.len() {
            return false;
        }
        let next = self.search_query[self.cursor..]
            .grapheme_indices(true)
            .next()
            .map_or(self.search_query.len(), |(idx, g)| {
                self.cursor + idx + g.len()
            });
        self.search_query.drain(self.cursor..next);
        true
    }
}

fn resolve_current_leaf_id(
    conversations: &[ConversationInfo],
    current_cid: &str,
) -> Option<String> {
    let by_id: HashMap<&str, &ConversationInfo> =
        conversations.iter().map(|c| (c.id.as_str(), c)).collect();
    let mut cur = Some(current_cid);
    let mut seen: HashSet<&str> = HashSet::new();
    while let Some(cid) = cur {
        if !seen.insert(cid) {
            break;
        }
        let conv = by_id.get(cid)?;
        if let Some(ref leaf) = conv.leaf_entry_id {
            return Some(leaf.clone());
        }
        if let Some(ref parent) = conv.parent {
            if !parent.at.is_empty() {
                return Some(parent.at.clone());
            }
            cur = Some(parent.conversation_id.as_str());
        } else {
            break;
        }
    }
    None
}

fn build_active_path(
    current_leaf_id: &Option<String>,
    parent_map: &HashMap<String, Option<String>>,
) -> HashSet<String> {
    let mut active = HashSet::new();
    let Some(mut cur) = current_leaf_id.as_deref() else {
        return active;
    };
    let mut guard = 0usize;
    loop {
        if !active.insert(cur.to_string()) {
            break;
        }
        guard += 1;
        if guard > parent_map.len() + 1 {
            break;
        }
        match parent_map.get(cur).and_then(Option::as_deref) {
            Some(pid) => cur = pid,
            None => break,
        }
    }
    active
}

fn prioritize_active(indices: &[usize], contains_active: &[bool]) -> Vec<usize> {
    let mut prioritized = Vec::with_capacity(indices.len());
    let mut rest = Vec::with_capacity(indices.len());
    for &idx in indices {
        if contains_active[idx] {
            prioritized.push(idx);
        } else {
            rest.push(idx);
        }
    }
    prioritized.extend(rest);
    prioritized
}

fn cmp_id_str(a: &str, b: &str) -> std::cmp::Ordering {
    match (a.parse::<u64>(), b.parse::<u64>()) {
        (Ok(na), Ok(nb)) => na.cmp(&nb),
        _ => a.cmp(b),
    }
}

fn format_kind_label(node: &TreeNode) -> String {
    match node.kind.as_str() {
        "user" => "user".to_string(),
        "assistant" => {
            if node.aborted {
                "assistant [aborted]".to_string()
            } else if node.error || node.is_error {
                "assistant [error]".to_string()
            } else {
                "assistant".to_string()
            }
        }
        "tool_result" => {
            let err_tag = if node.is_error || node.error {
                " [error]"
            } else {
                ""
            };
            format!("tool{err_tag}")
        }
        "user_shell" => {
            let tag = if node.aborted {
                " [cancelled]"
            } else if node.is_error || node.error {
                " [error]"
            } else {
                ""
            };
            format!("shell{tag}")
        }
        "compaction" => "compaction".to_string(),
        other => sanitize_single_line(other),
    }
}

fn format_node_preview(node: &TreeNode) -> String {
    let clean = sanitize_single_line(&node.preview);
    if !clean.is_empty() {
        clean
    } else if let Some(ref tool) = node.tool_name {
        format!("[{}]", sanitize_single_line(tool))
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ConversationParent, SessionSummary};

    fn dummy_session() -> SessionSummary {
        SessionSummary {
            session_id: "s1".to_string(),
            cwd: "/tmp/proj".to_string(),
            root_conversation_id: Some("1".to_string()),
            ..SessionSummary::default()
        }
    }

    fn conv(id: &str, parent: Option<(&str, &str)>, leaf: Option<&str>) -> ConversationInfo {
        ConversationInfo {
            id: id.to_string(),
            parent: parent.map(|(cid, at)| ConversationParent {
                conversation_id: cid.to_string(),
                at: at.to_string(),
            }),
            owner: Some("ownerless".to_string()),
            leaf_entry_id: leaf.map(str::to_string),
        }
    }

    fn node(
        id: &str,
        parent_id: Option<&str>,
        cid: &str,
        kind: &str,
        preview: &str,
        has_text: bool,
    ) -> TreeNode {
        TreeNode {
            id: id.to_string(),
            parent_id: parent_id.map(str::to_string),
            conversation_id: cid.to_string(),
            kind: kind.to_string(),
            preview: preview.to_string(),
            has_text,
            tool_name: None,
            aborted: false,
            is_error: false,
            error: false,
            created_at: Some(1_700_000_000_000),
        }
    }

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn press_mod(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    fn type_text(tree: &mut TreeSelector, s: &str) {
        for ch in s.chars() {
            assert_eq!(tree.key(press(KeyCode::Char(ch))), TreeChoice::Stay);
        }
    }

    #[test]
    fn linear_chain_stays_flat_without_rightward_staircasing() {
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![conv("1", None, Some("5"))],
            nodes: vec![
                node("1", None, "1", "user", "First prompt", true),
                node("2", Some("1"), "1", "assistant", "First reply", true),
                node("3", Some("2"), "1", "user", "Second prompt", true),
                node("4", Some("3"), "1", "assistant", "Second reply", true),
                node("5", Some("4"), "1", "user", "Third prompt", true),
            ],
            truncated: false,
        };

        let sel = TreeSelector::new(resp, "1");
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("5"));
        let lines = sel.lines();
        // Rows are lines[1..=5]; none should have connectors or extra indentation.
        for row in &lines[1..=5] {
            assert!(
                !row.contains("├─"),
                "unexpected branch connector in {row:?}"
            );
            assert!(
                !row.contains("└─"),
                "unexpected branch connector in {row:?}"
            );
            assert!(
                row.starts_with("> • #") || row.starts_with("  • #"),
                "linear row should stay at indent 0, got: {row:?}"
            );
        }
        assert!(
            lines[5].contains("[#1 *]"),
            "leaf badge missing: {}",
            lines[5]
        );
    }

    #[test]
    fn multi_branch_tree_prioritizes_active_branch_with_connectors_and_badges() {
        // Tree:
        //   1 (user, c1) -> 2 (assistant, c1)
        //     ├── 3 (user, c1) -> 4 (assistant, c1)   [branch #1]
        //     └── 5 (user, c2) -> 6 (assistant, c2)   [branch #2, ACTIVE]
        //   plus empty fork #3 at entry 2 (leaf_entry_id = 2, parent = (#1, 2))
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![
                conv("1", None, Some("4")),
                conv("2", Some(("1", "2")), Some("6")),
                conv("3", Some(("1", "2")), Some("2")),
            ],
            nodes: vec![
                node("1", None, "1", "user", "Root question", true),
                node("2", Some("1"), "1", "assistant", "Shared answer", true),
                node("3", Some("2"), "1", "user", "Old branch follow-up", true),
                node("4", Some("3"), "1", "assistant", "Old branch reply", true),
                node("5", Some("2"), "2", "user", "Active branch follow-up", true),
                node(
                    "6",
                    Some("5"),
                    "2",
                    "assistant",
                    "Active branch reply",
                    true,
                ),
            ],
            truncated: false,
        };

        let sel = TreeSelector::new(resp, "2");
        assert_eq!(sel.current_leaf_id(), Some("6"));
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("6"));

        let lines = sel.lines();
        // Header + 6 rows + footer
        assert_eq!(lines.len(), 8);
        // Active branch (#2: 5->6) must appear before sibling branch (#1: 3->4).
        assert!(lines[1].contains("• #1 user: Root question"));
        assert!(lines[2].contains("• #2 assistant [#3]: Shared answer"));
        assert!(
            lines[3].contains("├⊟ • #5 user: Active branch follow-up")
                || lines[3].contains("├─ • #5 user: Active branch follow-up"),
            "got: {}",
            lines[3]
        );
        assert!(
            lines[4].starts_with("> │     • #6 assistant [#2 *]: Active branch reply"),
            "expected │ gutter and indent+1 under active branch, got: {}",
            lines[4]
        );
        assert!(
            lines[5].contains("└⊟ #3 user: Old branch follow-up")
                || lines[5].contains("└─ #3 user: Old branch follow-up"),
            "sibling should not have active marker: {}",
            lines[5]
        );
        assert!(
            lines[6].starts_with("        #4 assistant [#1]: Old branch reply"),
            "last branch child should have blank gutter and [#1] badge, got: {}",
            lines[6]
        );
    }

    #[test]
    fn filter_modes_cycle_and_recalculate_visual_structure() {
        let mut tool_res = node("3", Some("2"), "1", "tool_result", "[read: a.rs]", false);
        tool_res.tool_name = Some("read".to_string());

        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![
                conv("1", None, Some("4")),
                conv("2", Some(("1", "2")), Some("5")),
            ],
            nodes: vec![
                node("1", None, "1", "user", "Read file", true),
                // Pure tool-call dispatch assistant node (has_text = false), hidden in Default
                // (not current leaf and no branch badge).
                node("2", Some("1"), "1", "assistant", "[tool: read a.rs]", false),
                tool_res,
                node("4", Some("3"), "1", "assistant", "Here is summary", true),
                node("5", Some("2"), "2", "user", "Alternative prompt", true),
            ],
            truncated: false,
        };

        let mut sel = TreeSelector::new(resp, "1");
        assert_eq!(sel.filter_mode(), FilterMode::Default);
        // Node #2 is hidden in Default, so #3 and #5 both attach to visible ancestor #1,
        // creating a branch point directly under #1!
        let default_ids: Vec<&str> = sel
            .filtered_nodes
            .iter()
            .map(|f| sel.nodes[f.node_idx].id.as_str())
            .collect();
        assert_eq!(default_ids, vec!["1", "3", "4", "5"]);
        let lines = sel.lines();
        assert!(
            lines[2].contains("├"),
            "expected branch connector on #3: {}",
            lines[2]
        );
        assert!(
            lines[4].contains("└"),
            "expected branch connector on #5: {}",
            lines[4]
        );

        // Tab -> NoTools (hides #3 tool_result too)
        assert_eq!(sel.key(press(KeyCode::Tab)), TreeChoice::Stay);
        assert_eq!(sel.filter_mode(), FilterMode::NoTools);
        let no_tools_ids: Vec<&str> = sel
            .filtered_nodes
            .iter()
            .map(|f| sel.nodes[f.node_idx].id.as_str())
            .collect();
        assert_eq!(no_tools_ids, vec!["1", "4", "5"]);

        // Ctrl-O -> UserOnly
        assert_eq!(
            sel.key(press_mod(KeyCode::Char('o'), KeyModifiers::CONTROL)),
            TreeChoice::Stay
        );
        assert_eq!(sel.filter_mode(), FilterMode::UserOnly);
        let user_ids: Vec<&str> = sel
            .filtered_nodes
            .iter()
            .map(|f| sel.nodes[f.node_idx].id.as_str())
            .collect();
        assert_eq!(user_ids, vec!["1", "5"]);

        // Alt-F -> All (shows #2 again)
        assert_eq!(
            sel.key(press_mod(KeyCode::Char('f'), KeyModifiers::ALT)),
            TreeChoice::Stay
        );
        assert_eq!(sel.filter_mode(), FilterMode::All);
        assert_eq!(sel.filtered_len(), 5);
    }

    #[test]
    fn search_filters_tokens_and_esc_clears_search_before_cancelling() {
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![conv("1", None, Some("3"))],
            nodes: vec![
                node("1", None, "1", "user", "Explain auth middleware", true),
                node(
                    "2",
                    Some("1"),
                    "1",
                    "assistant",
                    "Auth uses bearer token",
                    true,
                ),
                node("3", Some("2"), "1", "user", "Fix parser bug", true),
            ],
            truncated: false,
        };

        let mut sel = TreeSelector::new(resp, "1");
        type_text(&mut sel, "bearer");
        assert_eq!(sel.search_query(), "bearer");
        assert_eq!(sel.filtered_len(), 1);
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("2"));

        // First Esc clears search query without closing.
        assert_eq!(sel.key(press(KeyCode::Esc)), TreeChoice::Stay);
        assert_eq!(sel.search_query(), "");
        assert_eq!(sel.filtered_len(), 3);

        // Second Esc closes the tree overlay.
        assert_eq!(sel.key(press(KeyCode::Esc)), TreeChoice::Cancel);
    }

    #[test]
    fn fold_and_unfold_hide_and_restore_branch_descendants() {
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![
                conv("1", None, Some("4")),
                conv("2", Some(("1", "2")), Some("6")),
            ],
            nodes: vec![
                node("1", None, "1", "user", "Root", true),
                node("2", Some("1"), "1", "assistant", "Reply", true),
                node("3", Some("2"), "1", "user", "Branch A start", true),
                node("4", Some("3"), "1", "assistant", "Branch A leaf", true),
                node("5", Some("2"), "2", "user", "Branch B start", true),
                node("6", Some("5"), "2", "assistant", "Branch B leaf", true),
            ],
            truncated: false,
        };

        let mut sel = TreeSelector::new(resp, "1");
        // Cursor starts on #4 (Branch A leaf). Left jumps up to branch segment start #3.
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("4"));
        assert_eq!(sel.key(press(KeyCode::Left)), TreeChoice::Stay);
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("3"));

        // Left again on #3 folds Branch A, hiding #4.
        assert_eq!(sel.key(press(KeyCode::Left)), TreeChoice::Stay);
        assert!(sel.is_folded("3"));
        assert_eq!(sel.filtered_len(), 5);
        assert!(sel.lines().iter().any(|l| l.contains("├⊞ • #3")));

        // Right unfolds #3, restoring #4.
        assert_eq!(sel.key(press(KeyCode::Right)), TreeChoice::Stay);
        assert!(!sel.is_folded("3"));
        assert_eq!(sel.filtered_len(), 6);
    }

    #[test]
    fn empty_fork_conversation_without_explicit_leaf_resolves_parent_cut() {
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![
                conv("1", None, Some("2")),
                conv("2", Some(("1", "1")), None),
            ],
            nodes: vec![
                node("1", None, "1", "user", "Prompt", true),
                node("2", Some("1"), "1", "assistant", "Answer", true),
            ],
            truncated: false,
        };

        let sel = TreeSelector::new(resp, "2");
        assert_eq!(sel.current_leaf_id(), Some("1"));
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("1"));
        assert!(sel.lines()[1].contains("[#2 *]"));
    }

    #[test]
    fn enter_returns_node_metadata_including_sibling_conversation_id() {
        let resp = SessionTreeResponse {
            session: dummy_session(),
            conversations: vec![
                conv("1", None, Some("4")),
                conv("2", Some(("1", "2")), Some("5")),
            ],
            nodes: vec![
                node("1", None, "1", "user", "Root", true),
                node("2", Some("1"), "1", "assistant", "Shared", true),
                node("3", Some("2"), "1", "user", "Main next", true),
                node("4", Some("3"), "1", "assistant", "Main leaf", true),
                node("5", Some("2"), "2", "user", "Sibling step", true),
            ],
            truncated: false,
        };

        let mut sel = TreeSelector::new(resp, "1");
        // Move down from #4 to #5 (wraps or moves down; #4 is index 3, #5 is index 4).
        assert_eq!(sel.key(press(KeyCode::Down)), TreeChoice::Stay);
        assert_eq!(sel.selected_node().map(|n| n.id.as_str()), Some("5"));

        match sel.key(press(KeyCode::Enter)) {
            TreeChoice::Select(s) => {
                assert_eq!(s.node.id, "5");
                assert_eq!(s.node.conversation_id, "2");
                assert_eq!(s.leaf_conversations, vec!["2".to_string()]);
                assert!(!s.has_children);
            }
            other => panic!("expected Select, got {other:?}"),
        }
    }
}
