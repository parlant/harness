defmodule HWeb.CatalogState do
  @moduledoc """
  Normalized session catalog state and grouping/filtering helpers shared across
  `InboxLive`, `WorkspaceLive`, and `SessionLive`.

  Accepts both atom-keyed maps returned by `HWeb.Backend.list_sessions/1` and
  string-keyed JSON maps decoded from catalog snapshot/upsert frames without
  creating atoms from external input.
  """

  @type parent_ref :: %{
          session_id: String.t(),
          conversation_id: String.t(),
          at_entry_id: String.t() | nil,
          task_id: String.t() | nil,
          depth: pos_integer()
        }

  @type session :: %{
          session_id: String.t(),
          title: String.t() | nil,
          tags: [String.t()],
          env_id: String.t(),
          harness_id: String.t(),
          cwd: String.t(),
          root_conversation_id: String.t(),
          parent: parent_ref() | nil,
          role: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil,
          active: boolean(),
          attention: String.t(),
          activity_kind: String.t() | nil,
          activity_label: String.t() | nil,
          queued_count: non_neg_integer(),
          needs_attention: boolean(),
          archived: boolean(),
          loaded: boolean(),
          cwd_exists: boolean(),
          next_wake_at: integer() | nil,
          status: String.t()
        }

  @type t :: %{
          seq: non_neg_integer(),
          by_id: %{optional(String.t()) => session()},
          sessions: [session()]
        }

  @valid_attentions ~w(idle running sleeping retrying error quarantined archived)
  @valid_activity_kinds ~w(generation tool user_shell compaction retry)

  @doc "Creates an empty catalog state."
  @spec new() :: t()
  def new, do: %{seq: 0, by_id: %{}, sessions: []}

  @doc "Builds catalog state from a list of `SessionSummary` maps."
  @spec from_list([map()], non_neg_integer()) :: t()
  def from_list(raw_sessions, seq \\ 0) when is_list(raw_sessions) do
    by_id =
      raw_sessions
      |> Enum.map(&normalize_session/1)
      |> Map.new(&{&1.session_id, &1})

    %{seq: seq, by_id: by_id, sessions: sort_sessions(Map.values(by_id))}
  end

  @doc "Decodes and applies a catalog snapshot JSON frame."
  @spec apply_snapshot(t(), non_neg_integer(), binary()) :: {:ok, t()} | {:error, term()}
  def apply_snapshot(_state, seq, json_bin) when is_integer(seq) and is_binary(json_bin) do
    case JSON.decode(json_bin) do
      {:ok, %{"sessions" => raw_sessions} = decoded} when is_list(raw_sessions) ->
        frame_seq = if is_integer(decoded["seq"]), do: decoded["seq"], else: seq
        {:ok, from_list(raw_sessions, frame_seq)}

      {:ok, _} ->
        {:error, :invalid_snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Decodes and applies a live `{:catalog_frame, seq, json_bin}` frame."
  @spec apply_frame(t(), non_neg_integer(), binary()) :: {:ok, t()} | :stale | {:error, term()}
  def apply_frame(state, seq, json_bin) when is_integer(seq) and is_binary(json_bin) do
    if seq <= state.seq do
      :stale
    else
      case JSON.decode(json_bin) do
        {:ok, %{"type" => "upsert", "session" => raw}} when is_map(raw) ->
          session = normalize_session(raw)
          by_id = Map.put(state.by_id, session.session_id, session)
          {:ok, %{state | seq: seq, by_id: by_id, sessions: sort_sessions(Map.values(by_id))}}

        {:ok, %{"type" => "removed", "session_id" => sid}} when is_binary(sid) ->
          by_id = Map.delete(state.by_id, sid)
          {:ok, %{state | seq: seq, by_id: by_id, sessions: sort_sessions(Map.values(by_id))}}

        {:ok, _} ->
          {:error, :invalid_frame}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Normalizes an atom-keyed or string-keyed `SessionSummary` map."
  @spec normalize_session(map()) :: session()
  def normalize_session(raw) when is_map(raw) do
    status = field(raw, :status, "status") || "ok"
    raw_attention = field(raw, :attention, "attention")

    raw_archived = field(raw, :archived, "archived")
    archived = status == "archived" or raw_archived == true

    attention =
      cond do
        status == "quarantined" -> "quarantined"
        archived -> "archived"
        raw_attention in @valid_attentions -> raw_attention
        true -> "idle"
      end

    raw_kind = field(raw, :activity_kind, "activity_kind")
    activity_kind = if raw_kind in @valid_activity_kinds, do: raw_kind, else: nil

    raw_queued = field(raw, :queued_count, "queued_count")
    queued_count = if is_integer(raw_queued) and raw_queued >= 0, do: raw_queued, else: 0

    raw_na = field(raw, :needs_attention, "needs_attention")

    needs_attention =
      if archived do
        false
      else
        if is_boolean(raw_na) do
          raw_na
        else
          attention not in ["running", "sleeping", "retrying", "archived"]
        end
      end

    raw_loaded = field(raw, :loaded, "loaded")
    loaded = if is_boolean(raw_loaded), do: raw_loaded, else: not archived

    raw_cwd_exists = field(raw, :cwd_exists, "cwd_exists")
    cwd_exists = if is_boolean(raw_cwd_exists), do: raw_cwd_exists, else: true

    %{
      session_id: to_string(field(raw, :session_id, "session_id") || ""),
      title: field(raw, :title, "title"),
      tags: normalize_tags(field(raw, :tags, "tags")),
      env_id: field(raw, :env_id, "env_id") || "host",
      harness_id: field(raw, :harness_id, "harness_id") || "coding",
      cwd: field(raw, :cwd, "cwd") || "/",
      root_conversation_id:
        to_string(field(raw, :root_conversation_id, "root_conversation_id") || "1"),
      parent: normalize_parent(field(raw, :parent, "parent")),
      role: normalize_role(field(raw, :role, "role")),
      created_at: field(raw, :created_at, "created_at"),
      updated_at: field(raw, :updated_at, "updated_at"),
      active: field(raw, :active, "active") == true,
      attention: attention,
      activity_kind: activity_kind,
      activity_label: field(raw, :activity_label, "activity_label"),
      queued_count: queued_count,
      needs_attention: needs_attention,
      archived: archived,
      loaded: loaded,
      cwd_exists: cwd_exists,
      next_wake_at: field(raw, :next_wake_at, "next_wake_at"),
      status: status
    }
  end

  @doc "Normalizes an optional `parent` lineage map (atom or string keys)."
  @spec normalize_parent(term()) :: parent_ref() | nil
  def normalize_parent(raw) when is_map(raw) do
    case normalize_non_empty_string(field(raw, :session_id, "session_id")) do
      nil ->
        nil

      parent_sid ->
        %{
          session_id: parent_sid,
          conversation_id:
            normalize_id_string(field(raw, :conversation_id, "conversation_id")) || "1",
          at_entry_id: normalize_id_string(field(raw, :at_entry_id, "at_entry_id")),
          task_id: normalize_id_string(field(raw, :task_id, "task_id")),
          depth: normalize_depth(field(raw, :depth, "depth"))
        }
    end
  end

  def normalize_parent(_), do: nil

  @doc "Returns `true` when the session is a root session (`parent == nil`)."
  @spec root_session?(map()) :: boolean()
  def root_session?(%{parent: nil}), do: true
  def root_session?(%{parent: _}), do: false
  def root_session?(session) when is_map(session), do: is_nil(field(session, :parent, "parent"))
  def root_session?(_), do: false

  @doc "Returns `true` when the session is a spawned subsession (`parent != nil`)."
  @spec subsession?(map()) :: boolean()
  def subsession?(session) when is_map(session), do: not root_session?(session)
  def subsession?(_), do: false

  @doc "Returns the number of subsessions in `sessions`."
  @spec subsession_count([session()]) :: non_neg_integer()
  def subsession_count(sessions) when is_list(sessions) do
    Enum.count(sessions, &subsession?/1)
  end

  @doc "Returns true if a root session needs human attention (not a subsession, not archived, flagged `needs_attention`, and not processing)."
  @spec needs_attention?(session()) :: boolean()
  def needs_attention?(%{parent: parent}) when not is_nil(parent), do: false

  def needs_attention?(%{archived: false, needs_attention: true} = session) do
    not processing?(session)
  end

  def needs_attention?(_), do: false

  @doc "Returns true if a session is running, sleeping, or retrying a provider error."
  @spec processing?(session()) :: boolean()
  def processing?(%{attention: att}) when att in ["running", "sleeping", "retrying"], do: true
  def processing?(_), do: false

  @doc "Returns true if the session is unarchived, whether loaded or not."
  @spec active_inbox?(session()) :: boolean()
  def active_inbox?(%{archived: archived}), do: not archived

  @doc """
  Computes live inbox / attention / processing / archived / total counts over root
  sessions, plus `subsessions` and `subsessions_running` totals.
  """
  @spec counts([session()]) :: %{
          inbox: non_neg_integer(),
          attention: non_neg_integer(),
          error: non_neg_integer(),
          idle: non_neg_integer(),
          processing: non_neg_integer(),
          running: non_neg_integer(),
          sleeping: non_neg_integer(),
          archived: non_neg_integer(),
          all: non_neg_integer(),
          retrying: non_neg_integer(),
          subsessions: non_neg_integer(),
          subsessions_running: non_neg_integer()
        }
  def counts(sessions) when is_list(sessions) do
    initial = %{
      inbox: 0,
      attention: 0,
      error: 0,
      idle: 0,
      processing: 0,
      running: 0,
      sleeping: 0,
      archived: 0,
      all: 0,
      retrying: 0,
      subsessions: 0,
      subsessions_running: 0
    }

    Enum.reduce(sessions, initial, fn s, acc ->
      if subsession?(s) do
        running_inc = if not s.archived and processing?(s), do: 1, else: 0

        %{
          acc
          | subsessions: acc.subsessions + 1,
            subsessions_running: acc.subsessions_running + running_inc
        }
      else
        acc = %{acc | all: acc.all + 1}
        acc = if active_inbox?(s), do: %{acc | inbox: acc.inbox + 1}, else: acc
        acc = if s.archived, do: %{acc | archived: acc.archived + 1}, else: acc

        cond do
          needs_attention?(s) and s.attention in ["error", "quarantined"] ->
            %{acc | attention: acc.attention + 1, error: acc.error + 1}

          needs_attention?(s) ->
            %{acc | attention: acc.attention + 1, idle: acc.idle + 1}

          s.attention == "running" and not s.archived ->
            %{acc | processing: acc.processing + 1, running: acc.running + 1}

          s.attention == "sleeping" and not s.archived ->
            %{acc | processing: acc.processing + 1, sleeping: acc.sleeping + 1}

          s.attention == "retrying" and not s.archived ->
            %{acc | processing: acc.processing + 1, retrying: acc.retrying + 1}

          true ->
            acc
        end
      end
    end)
  end

  @doc """
  Filters sessions by mode (`\"inbox\"` | `\"attention\"` | `\"archived\"` | `\"all\"`),
  optional search query, and `:include_subsessions` (default `false`).
  """
  @spec filter_sessions([session()], String.t(), String.t(), keyword()) :: [session()]
  def filter_sessions(sessions, filter_mode \\ "inbox", query \\ "", opts \\ [])
      when is_list(sessions) and is_list(opts) do
    q = query |> to_string() |> String.trim() |> String.downcase()
    include_subsessions = Keyword.get(opts, :include_subsessions, false)

    if include_subsessions do
      filter_with_subsessions(sessions, filter_mode, q)
    else
      sessions
      |> Enum.filter(&root_session?/1)
      |> Enum.filter(fn s ->
        mode_matches?(s, filter_mode) and query_matches?(s, q)
      end)
    end
  end

  @doc """
  Groups sessions by `{env_id, cwd}` working directory root.

  By default (`include_subsessions: false`), subsessions are excluded and each
  session carries `children: []`.

  When `include_subsessions: true`, subsessions are attached hierarchically under
  their ancestor root session (even when a child runs in a different worktree
  `cwd`). Orphan subsessions whose parent is not present in `sessions` fall back
  to their own `{env_id, cwd}` workspace group.

  Groups are ordered by urgency tier (error/quarantined needing attention, then
  other needs-attention, then processing, then cleared/dismissed, then archived)
  and recency (`updated_at` descending).
  """
  @spec group_by_workspace([session()], keyword()) :: [map()]
  def group_by_workspace(sessions, opts \\ []) when is_list(sessions) and is_list(opts) do
    home = Keyword.get(opts, :home, System.user_home())
    include_subsessions = Keyword.get(opts, :include_subsessions, false)

    top_level_nodes =
      if include_subsessions do
        build_hierarchy_roots(sessions)
      else
        sessions
        |> Enum.filter(&root_session?/1)
        |> Enum.map(&Map.put(&1, :children, []))
      end

    top_level_nodes
    |> Enum.group_by(&{&1.env_id, &1.cwd})
    |> Enum.map(fn {{env_id, cwd}, group_sessions} ->
      ordered = Enum.sort_by(group_sessions, &session_sort_key/1)
      flat_group_sessions = flatten_hierarchy(ordered)
      group_counts = counts(flat_group_sessions)
      top_rank = ordered |> Enum.map(&top_level_tier/1) |> Enum.min(fn -> 99 end)

      latest_updated =
        flat_group_sessions |> Enum.map(&(&1.updated_at || 0)) |> Enum.max(fn -> 0 end)

      %{
        key: "#{env_id}:#{cwd}",
        env_id: env_id,
        cwd: cwd,
        label: format_workspace_label(env_id, cwd, home),
        sessions: ordered,
        counts: group_counts,
        top_rank: top_rank,
        latest_updated: latest_updated
      }
    end)
    |> Enum.sort_by(fn g -> {g.top_rank, -g.latest_updated, g.label} end)
  end

  @doc """
  Returns the next attention-needing session (excluding `current_session_id` if
  another exists), prioritizing `error`/`quarantined` before `idle` and then
  recency. Returns `nil` when no other session needs attention.
  """
  @spec next_attention_session([session()], String.t() | nil) :: session() | nil
  def next_attention_session(sessions, current_session_id \\ nil) when is_list(sessions) do
    candidates =
      sessions
      |> Enum.filter(&needs_attention?/1)
      |> Enum.reject(&(&1.session_id == current_session_id))
      |> Enum.sort_by(&session_sort_key/1)

    List.first(candidates)
  end

  @doc "Formats `{env_id, cwd}` with `~/` shortening for `host` paths."
  @spec format_workspace_label(String.t(), String.t(), String.t() | nil) :: String.t()
  def format_workspace_label("host", cwd, home) when is_binary(cwd) do
    shorten_home(cwd, home)
  end

  def format_workspace_label(env_id, cwd, _home) when is_binary(cwd) do
    "#{env_id}: #{cwd}"
  end

  @doc "Returns a concise secondary label for a session's current activity or failure."
  @spec status_detail(session()) :: String.t() | nil
  def status_detail(%{archived: true}), do: nil
  def status_detail(%{attention: "archived"}), do: nil

  def status_detail(%{attention: "quarantined", activity_label: label}),
    do: label || "quarantined"

  def status_detail(%{attention: "error", activity_label: label}),
    do: label || "error"

  def status_detail(%{attention: "running", activity_label: label})
      when is_binary(label) and label != "",
      do: label

  def status_detail(%{attention: "running", activity_kind: "user_shell"}), do: "shell"
  def status_detail(%{attention: "running", activity_kind: "compaction"}), do: "compact"
  def status_detail(%{attention: "running", activity_kind: kind}) when is_binary(kind), do: kind
  def status_detail(%{attention: "running"}), do: "generation"

  def status_detail(%{attention: attention, activity_label: label})
      when attention in ["sleeping", "retrying"] and is_binary(label) and label != "",
      do: label

  def status_detail(%{attention: attention}) when attention in ["sleeping", "retrying"],
    do: "retrying"

  def status_detail(_), do: nil

  defp filter_with_subsessions(sessions, "attention", q) do
    by_id = Map.new(sessions, &{&1.session_id, &1})

    matching_root_ids =
      sessions
      |> Enum.filter(fn s ->
        root_session?(s) and needs_attention?(s) and query_matches?(s, q)
      end)
      |> MapSet.new(& &1.session_id)

    Enum.filter(sessions, fn s ->
      if root_session?(s) do
        MapSet.member?(matching_root_ids, s.session_id)
      else
        not s.archived and
          case ancestor_root_id(s, by_id) do
            nil -> false
            root_id -> MapSet.member?(matching_root_ids, root_id)
          end
      end
    end)
  end

  defp filter_with_subsessions(sessions, filter_mode, q) do
    by_id = Map.new(sessions, &{&1.session_id, &1})

    eligible =
      Enum.filter(sessions, fn s ->
        if root_session?(s) do
          mode_matches?(s, filter_mode)
        else
          case filter_mode do
            "inbox" -> not s.archived
            "archived" -> s.archived
            _ -> true
          end
        end
      end)

    if q == "" do
      eligible
    else
      eligible_by_id = Map.new(eligible, &{&1.session_id, &1})

      direct_ids =
        eligible
        |> Enum.filter(&query_matches?(&1, q))
        |> MapSet.new(& &1.session_id)

      kept_ids =
        Enum.reduce(direct_ids, direct_ids, fn sid, acc ->
          add_ancestor_ids(sid, by_id, acc)
        end)

      sessions
      |> Enum.filter(fn s ->
        MapSet.member?(kept_ids, s.session_id) and
          (Map.has_key?(eligible_by_id, s.session_id) or root_session?(s))
      end)
    end
  end

  defp mode_matches?(s, "inbox"), do: active_inbox?(s)
  defp mode_matches?(s, "attention"), do: needs_attention?(s)
  defp mode_matches?(s, "archived"), do: s.archived
  defp mode_matches?(_s, _), do: true

  defp query_matches?(_s, ""), do: true

  defp query_matches?(s, q) do
    String.contains?(String.downcase(s.session_id), q) or
      String.contains?(String.downcase(s.title || ""), q) or
      String.contains?(String.downcase(s.cwd), q) or
      String.contains?(String.downcase(s.env_id), q) or
      String.contains?(String.downcase(s.activity_label || ""), q) or
      String.contains?(String.downcase(s.role || ""), q)
  end

  defp ancestor_root_id(session, by_id), do: ancestor_root_id(session, by_id, MapSet.new())

  defp ancestor_root_id(%{parent: nil, session_id: sid}, _by_id, _seen), do: sid

  defp ancestor_root_id(%{session_id: sid, parent: %{session_id: parent_sid}}, by_id, seen) do
    if MapSet.member?(seen, sid) do
      nil
    else
      case Map.get(by_id, parent_sid) do
        nil -> nil
        parent -> ancestor_root_id(parent, by_id, MapSet.put(seen, sid))
      end
    end
  end

  defp ancestor_root_id(_, _by_id, _seen), do: nil

  defp add_ancestor_ids(sid, by_id, acc) do
    case Map.get(by_id, sid) do
      %{parent: %{session_id: parent_sid}} ->
        if Map.has_key?(by_id, parent_sid) and not MapSet.member?(acc, parent_sid) do
          add_ancestor_ids(parent_sid, by_id, MapSet.put(acc, parent_sid))
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp build_hierarchy_roots(sessions) do
    by_id = Map.new(sessions, &{&1.session_id, &1})

    children_by_parent =
      sessions
      |> Enum.filter(fn s ->
        case s.parent do
          %{session_id: parent_sid} ->
            parent_sid != s.session_id and Map.has_key?(by_id, parent_sid)

          _ ->
            false
        end
      end)
      |> Enum.group_by(& &1.parent.session_id)

    top_level =
      Enum.filter(sessions, fn s ->
        case s.parent do
          nil ->
            true

          %{session_id: parent_sid} ->
            not Map.has_key?(by_id, parent_sid) or parent_sid == s.session_id
        end
      end)

    Enum.map(top_level, &attach_children(&1, children_by_parent, MapSet.new([&1.session_id])))
  end

  defp attach_children(session, children_by_parent, seen) do
    children =
      children_by_parent
      |> Map.get(session.session_id, [])
      |> Enum.reject(&MapSet.member?(seen, &1.session_id))
      |> Enum.sort_by(&child_sort_key/1)
      |> Enum.map(&attach_children(&1, children_by_parent, MapSet.put(seen, &1.session_id)))

    Map.put(session, :children, children)
  end

  defp flatten_hierarchy(nodes) do
    Enum.flat_map(nodes, fn node ->
      [node | flatten_hierarchy(Map.get(node, :children, []))]
    end)
  end

  defp child_sort_key(s) do
    {s.created_at || 0, s.session_id}
  end

  defp top_level_tier(%{parent: parent, archived: archived}) when not is_nil(parent),
    do: if(archived, do: 4, else: 3)

  defp top_level_tier(s), do: session_tier(s)

  defp normalize_role(role) when is_binary(role) do
    trimmed = String.trim(role)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_role(_), do: nil

  defp normalize_non_empty_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_non_empty_string(_), do: nil

  defp normalize_id_string(nil), do: nil
  defp normalize_id_string(val) when is_integer(val) and val > 0, do: Integer.to_string(val)

  defp normalize_id_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_id_string(_), do: nil

  defp normalize_depth(val) when is_integer(val) and val > 0, do: val

  defp normalize_depth(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp normalize_depth(_), do: 1

  defp shorten_home(cwd, home) when is_binary(home) and home != "" do
    clean_home = String.trim_trailing(home, "/")

    cond do
      cwd == clean_home ->
        "~"

      String.starts_with?(cwd, clean_home <> "/") ->
        "~" <> String.replace_prefix(cwd, clean_home, "")

      true ->
        cwd
    end
  end

  defp shorten_home(cwd, _home), do: cwd

  defp sort_sessions(sessions) do
    Enum.sort_by(sessions, &{&1.updated_at || 0, &1.session_id}, :desc)
  end

  defp session_sort_key(s) do
    {session_tier(s), -(s.updated_at || 0), s.session_id}
  end

  defp session_tier(s) do
    cond do
      s.archived -> 4
      needs_attention?(s) and s.attention in ["error", "quarantined"] -> 0
      needs_attention?(s) -> 1
      processing?(s) -> 2
      true -> 3
    end
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags |> Enum.filter(&(is_binary(&1) and &1 != "" and String.valid?(&1))) |> Enum.uniq()
  end

  defp normalize_tags(_), do: []

  defp field(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(map, string_key)
    end
  end
end
