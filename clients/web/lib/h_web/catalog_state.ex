defmodule HWeb.CatalogState do
  @moduledoc """
  Normalized session catalog state and grouping/filtering helpers shared across
  `InboxLive`, `WorkspaceLive`, and `SessionLive`.

  Accepts both atom-keyed maps returned by `HWeb.Backend.list_sessions/1` and
  string-keyed JSON maps decoded from catalog snapshot/upsert frames without
  creating atoms from external input.
  """

  @type session :: %{
          session_id: String.t(),
          title: String.t() | nil,
          env_id: String.t(),
          harness_id: String.t(),
          cwd: String.t(),
          root_conversation_id: String.t(),
          created_at: integer() | nil,
          updated_at: integer() | nil,
          active: boolean(),
          attention: String.t(),
          activity_kind: String.t() | nil,
          activity_label: String.t() | nil,
          queued_count: non_neg_integer(),
          next_wake_at: integer() | nil,
          status: String.t()
        }

  @type t :: %{
          seq: non_neg_integer(),
          by_id: %{optional(String.t()) => session()},
          sessions: [session()]
        }

  @valid_attentions ~w(idle running sleeping error quarantined)
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

    attention =
      cond do
        status == "quarantined" -> "quarantined"
        raw_attention in @valid_attentions -> raw_attention
        true -> "idle"
      end

    raw_kind = field(raw, :activity_kind, "activity_kind")
    activity_kind = if raw_kind in @valid_activity_kinds, do: raw_kind, else: nil

    raw_queued = field(raw, :queued_count, "queued_count")
    queued_count = if is_integer(raw_queued) and raw_queued >= 0, do: raw_queued, else: 0

    %{
      session_id: to_string(field(raw, :session_id, "session_id") || ""),
      title: field(raw, :title, "title"),
      env_id: field(raw, :env_id, "env_id") || "host",
      harness_id: field(raw, :harness_id, "harness_id") || "coding",
      cwd: field(raw, :cwd, "cwd") || "/",
      root_conversation_id:
        to_string(field(raw, :root_conversation_id, "root_conversation_id") || "1"),
      created_at: field(raw, :created_at, "created_at"),
      updated_at: field(raw, :updated_at, "updated_at"),
      active: field(raw, :active, "active") == true,
      attention: attention,
      activity_kind: activity_kind,
      activity_label: field(raw, :activity_label, "activity_label"),
      queued_count: queued_count,
      next_wake_at: field(raw, :next_wake_at, "next_wake_at"),
      status: status
    }
  end

  @doc "Returns true if a session needs human attention (`error`, `quarantined`, or `idle`)."
  @spec needs_attention?(session()) :: boolean()
  def needs_attention?(%{attention: att}) when att in ["error", "quarantined", "idle"], do: true
  def needs_attention?(_), do: false

  @doc "Returns true if a session is currently processing (`running` or `sleeping`)."
  @spec processing?(session()) :: boolean()
  def processing?(%{attention: att}) when att in ["running", "sleeping"], do: true
  def processing?(_), do: false

  @doc "Computes live attention / processing / total counts for a session list."
  @spec counts([session()]) :: %{
          all: non_neg_integer(),
          attention: non_neg_integer(),
          error: non_neg_integer(),
          idle: non_neg_integer(),
          processing: non_neg_integer(),
          running: non_neg_integer(),
          sleeping: non_neg_integer()
        }
  def counts(sessions) when is_list(sessions) do
    Enum.reduce(
      sessions,
      %{all: 0, attention: 0, error: 0, idle: 0, processing: 0, running: 0, sleeping: 0},
      fn s, acc ->
        acc = %{acc | all: acc.all + 1}

        case s.attention do
          att when att in ["error", "quarantined"] ->
            %{acc | attention: acc.attention + 1, error: acc.error + 1}

          "idle" ->
            %{acc | attention: acc.attention + 1, idle: acc.idle + 1}

          "running" ->
            %{acc | processing: acc.processing + 1, running: acc.running + 1}

          "sleeping" ->
            %{acc | processing: acc.processing + 1, sleeping: acc.sleeping + 1}

          _ ->
            acc
        end
      end
    )
  end

  @doc "Filters sessions by attention mode (`\"all\"` | `\"attention\"`) and optional search query."
  @spec filter_sessions([session()], String.t(), String.t()) :: [session()]
  def filter_sessions(sessions, filter_mode \\ "all", query \\ "") do
    q = query |> to_string() |> String.trim() |> String.downcase()

    sessions
    |> Enum.filter(fn s ->
      mode_ok =
        case filter_mode do
          "attention" -> needs_attention?(s)
          _ -> true
        end

      query_ok =
        q == "" or
          String.contains?(String.downcase(s.session_id), q) or
          String.contains?(String.downcase(s.title || ""), q) or
          String.contains?(String.downcase(s.cwd), q) or
          String.contains?(String.downcase(s.env_id), q) or
          String.contains?(String.downcase(s.activity_label || ""), q)

      mode_ok and query_ok
    end)
  end

  @doc """
  Groups sessions by `{env_id, cwd}` working directory root.

  Groups are ordered by urgency (groups with `error`/`quarantined` first, then
  `idle`, then processing-only groups) and recency (`updated_at` descending).
  Within each group, sessions follow the same urgency + recency ordering.
  """
  @spec group_by_workspace([session()], keyword()) :: [map()]
  def group_by_workspace(sessions, opts \\ []) when is_list(sessions) do
    home = Keyword.get(opts, :home, System.user_home())

    sessions
    |> Enum.group_by(&{&1.env_id, &1.cwd})
    |> Enum.map(fn {{env_id, cwd}, group_sessions} ->
      ordered = Enum.sort_by(group_sessions, &session_sort_key/1)
      group_counts = counts(ordered)
      top_rank = ordered |> Enum.map(&attention_rank(&1.attention)) |> Enum.min(fn -> 99 end)
      latest_updated = ordered |> Enum.map(&(&1.updated_at || 0)) |> Enum.max(fn -> 0 end)

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

  def status_detail(%{attention: "sleeping", activity_label: label})
      when is_binary(label) and label != "",
      do: label

  def status_detail(%{attention: "sleeping"}), do: "retrying"
  def status_detail(_), do: nil

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
    {attention_rank(s.attention), -(s.updated_at || 0), s.session_id}
  end

  defp attention_rank("error"), do: 0
  defp attention_rank("quarantined"), do: 0
  defp attention_rank("idle"), do: 1
  defp attention_rank("sleeping"), do: 2
  defp attention_rank("running"), do: 3
  defp attention_rank(_), do: 4

  defp field(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(map, string_key)
    end
  end
end
