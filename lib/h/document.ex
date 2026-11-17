defmodule H.Document do
  @moduledoc """
  Versioned pure-functional conversation documents (`agent`, `live`, `inbox`, `usage`),
  JSON delta operations matching `priv/static/transcript.js`, and fork policy resolution.
  """

  @definitions %{
    "agent" => %{
      kind: "agent",
      version: 1,
      scope: :conversation,
      history: :rewindable,
      fork: :as_of
    },
    "live" => %{
      kind: "live",
      version: 1,
      scope: :conversation,
      history: :latest,
      fork: :initial
    },
    "inbox" => %{
      kind: "inbox",
      version: 1,
      scope: :conversation,
      history: :latest,
      fork: :initial
    },
    "usage" => %{
      kind: "usage",
      version: 1,
      scope: :conversation,
      history: :latest,
      fork: :initial
    }
  }

  @default_tools ["read", "write", "edit", "bash", "search_history"]

  @type op ::
          [String.t() | term()]

  @doc "Returns metadata for all built-in document kinds."
  @spec definitions() :: %{String.t() => map()}
  def definitions, do: @definitions

  @doc "Returns the definition map for a built-in document kind."
  @spec definition(String.t()) :: {:ok, map()} | :error
  def definition(kind) when is_binary(kind), do: Map.fetch(@definitions, kind)

  @doc "Returns the initial value for a built-in conversation document."
  @spec initial(String.t(), keyword()) :: term()
  def initial(kind, opts \\ [])

  def initial("agent", opts) do
    %{
      "model" => Keyword.get(opts, :default_model),
      "thinking" => "medium",
      "system_prompt" => nil,
      "instructions" => nil,
      "tools" => @default_tools,
      "max_turns" => 50
    }
  end

  def initial("live", _opts), do: %{}
  def initial("inbox", _opts), do: []

  def initial("usage", _opts) do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "cost" => 0.0
    }
  end

  @doc "Wraps a document value in a storage record map."
  @spec wrap(String.t(), term()) :: map()
  def wrap(kind, value) when is_binary(kind) do
    %{"kind" => kind, "version" => 1, "value" => value}
  end

  @doc "Unwraps a stored document record map, falling back to `initial/2` when `nil`."
  @spec unwrap(nil | map(), String.t(), keyword()) :: term()
  def unwrap(record, kind, opts \\ [])
  def unwrap(nil, kind, opts), do: initial(kind, opts)
  def unwrap(%{"value" => value}, _kind, _opts), do: value
  def unwrap(%{value: value}, _kind, _opts), do: value
  def unwrap(other, _kind, _opts), do: other

  @doc "Applies a list of JSON delta operations to a document immutably."
  @spec apply_ops(term(), [op()]) :: term()
  def apply_ops(doc, ops) when is_list(ops) do
    Enum.reduce(ops, doc, &apply_op(&2, &1))
  end

  @doc "Applies a single JSON delta operation (`replace`, `r`, `set`, `append_text`, `delete`)."
  @spec apply_op(term(), op()) :: term()
  def apply_op(_doc, ["replace", value]), do: value
  def apply_op(_doc, ["r", value]), do: value

  def apply_op(doc, ["set", path, value]) when is_list(path) do
    set_at_path(doc, path, value)
  end

  def apply_op(doc, ["append_text", path, delta]) when is_list(path) do
    delta_str = if is_nil(delta), do: "", else: to_string(delta)
    prev = get_at_path(doc, path)
    next_text = if(is_binary(prev), do: prev, else: "") <> delta_str
    set_at_path(doc, path, next_text)
  end

  def apply_op(doc, ["delete", path]) when is_list(path) do
    delete_at_path(doc, path)
  end

  def apply_op(doc, _unknown), do: doc

  @doc "Replaces a document value and emits `[\"replace\", value]`."
  @spec replace(term(), term()) :: {term(), [op()]}
  def replace(_doc, new_value), do: {new_value, [["replace", new_value]]}

  @doc "Sets a path inside a document and returns `{new_doc, [op]}`."
  @spec set(term(), [String.t() | non_neg_integer()], term()) :: {term(), [op()]}
  def set(doc, path, value) when is_list(path) do
    op = ["set", path, value]
    {apply_op(doc, op), [op]}
  end

  @doc "Appends text at a path inside a document and returns `{new_doc, [op]}`."
  @spec append_text(term(), [String.t() | non_neg_integer()], String.t()) :: {term(), [op()]}
  def append_text(doc, path, delta) when is_list(path) and is_binary(delta) do
    op = ["append_text", path, delta]
    {apply_op(doc, op), [op]}
  end

  @doc "Deletes a path inside a document and returns `{new_doc, [op]}`."
  @spec delete(term(), [String.t() | non_neg_integer()]) :: {term(), [op()]}
  def delete(doc, path) when is_list(path) do
    op = ["delete", path]
    {apply_op(doc, op), [op]}
  end

  @doc """
  Applies validated configuration updates to an `"agent"` document and emits
  minimal `["set", [key], val]` delta ops.
  """
  @spec configure_agent(map(), map()) :: {map(), [op()]}
  def configure_agent(agent, updates) when is_map(agent) and is_map(updates) do
    allowed = ["model", "thinking", "system_prompt", "instructions", "tools", "max_turns"]

    Enum.reduce(allowed, {agent, []}, fn key, {acc_doc, acc_ops} ->
      atom_key = String.to_existing_atom(key)

      cond do
        Map.has_key?(updates, key) ->
          val = Map.fetch!(updates, key)
          {next_doc, ops} = set(acc_doc, [key], val)
          {next_doc, acc_ops ++ ops}

        Map.has_key?(updates, atom_key) ->
          val = Map.fetch!(updates, atom_key)
          {next_doc, ops} = set(acc_doc, [key], val)
          {next_doc, acc_ops ++ ops}

        true ->
          {acc_doc, acc_ops}
      end
    end)
  end

  @doc """
  Accumulates turn usage metrics into the `"usage"` document and returns
  `{new_usage, ops}`.
  """
  @spec accumulate_usage(map(), map()) :: {map(), [op()]}
  def accumulate_usage(usage_doc, turn_usage) when is_map(usage_doc) and is_map(turn_usage) do
    in_tok = num_field(turn_usage, ["input_tokens", :input_tokens, "input", :input], 0)
    out_tok = num_field(turn_usage, ["output_tokens", :output_tokens, "output", :output], 0)

    total_tok =
      num_field(
        turn_usage,
        ["total_tokens", :total_tokens, "total", :total],
        in_tok + out_tok
      )

    cost = float_field(turn_usage, ["cost", :cost, "total_cost", :total_cost], 0.0)

    next_usage = %{
      "input_tokens" => (usage_doc["input_tokens"] || 0) + in_tok,
      "output_tokens" => (usage_doc["output_tokens"] || 0) + out_tok,
      "total_tokens" => (usage_doc["total_tokens"] || 0) + total_tok,
      "cost" => Float.round((usage_doc["cost"] || 0.0) * 1.0 + cost, 8)
    }

    if next_usage == usage_doc do
      {usage_doc, []}
    else
      {next_usage, [["replace", next_usage]]}
    end
  end

  @doc """
  Computes initial documents for a forked conversation at `at_entry_seq`.

  `"agent"` uses `fork: :as_of` (read from storage at `as_of_seq: at_entry_seq`),
  while `"live"`, `"inbox"`, and `"usage"` use `fork: :initial`.
  """
  @spec fork_docs(H.Storage.t(), pos_integer(), non_neg_integer(), keyword()) ::
          {:ok, %{String.t() => term()}, H.Storage.t()} | {:error, term()}
  def fork_docs(store, parent_cid, at_entry_seq, opts \\ [])
      when is_integer(parent_cid) and is_integer(at_entry_seq) do
    case H.Storage.get_doc(store, {:conversation, parent_cid, "agent"}, as_of_seq: at_entry_seq) do
      {:ok, agent_record, next_store} ->
        docs = %{
          "agent" => unwrap(agent_record, "agent", opts),
          "live" => initial("live", opts),
          "inbox" => initial("inbox", opts),
          "usage" => initial("usage", opts)
        }

        {:ok, docs, next_store}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Path traversal helpers matching priv/static/transcript.js

  defp get_at_path(root, []), do: root
  defp get_at_path(nil, _path), do: nil

  defp get_at_path(list, [head | tail]) when is_list(list) do
    case parse_index(head) do
      {:ok, idx} when idx >= 0 ->
        case Enum.fetch(list, idx) do
          {:ok, elem} -> get_at_path(elem, tail)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp get_at_path(map, [head | tail]) when is_map(map) do
    key = to_string(head)

    case Map.fetch(map, key) do
      {:ok, val} -> get_at_path(val, tail)
      :error -> nil
    end
  end

  defp get_at_path(_other, _path), do: nil

  defp set_at_path(_root, [], value), do: value

  defp set_at_path(list, [head | tail], value) when is_list(list) do
    case parse_index(head) do
      {:ok, idx} when idx >= 0 ->
        padded =
          if idx >= length(list) do
            list ++ List.duplicate(nil, idx - length(list) + 1)
          else
            list
          end

        List.update_at(padded, idx, &set_at_path(&1, tail, value))

      _ ->
        set_at_path(%{}, [head | tail], value)
    end
  end

  defp set_at_path(map, [head | tail], value) when is_map(map) do
    key = to_string(head)
    existing = Map.get(map, key)
    Map.put(map, key, set_at_path(existing, tail, value))
  end

  defp set_at_path(_other, [head | tail], value) do
    key = to_string(head)
    %{key => set_at_path(nil, tail, value)}
  end

  defp delete_at_path(root, []), do: root
  defp delete_at_path(nil, _path), do: nil

  defp delete_at_path(list, [head]) when is_list(list) do
    case parse_index(head) do
      {:ok, idx} when idx >= 0 and idx < length(list) -> List.delete_at(list, idx)
      _ -> list
    end
  end

  defp delete_at_path(map, [head]) when is_map(map) do
    Map.delete(map, to_string(head))
  end

  defp delete_at_path(list, [head | tail]) when is_list(list) do
    case parse_index(head) do
      {:ok, idx} when idx >= 0 and idx < length(list) ->
        List.update_at(list, idx, &delete_at_path(&1, tail))

      _ ->
        list
    end
  end

  defp delete_at_path(map, [head | tail]) when is_map(map) do
    key = to_string(head)

    case Map.fetch(map, key) do
      {:ok, child} -> Map.put(map, key, delete_at_path(child, tail))
      :error -> map
    end
  end

  defp delete_at_path(other, _path), do: other

  defp parse_index(seg) when is_integer(seg) and seg >= 0, do: {:ok, seg}

  defp parse_index(seg) when is_binary(seg) do
    if Regex.match?(~r/^\d+$/, seg) do
      {:ok, String.to_integer(seg)}
    else
      :error
    end
  end

  defp parse_index(_), do: :error

  defp num_field(map, keys, default) do
    Enum.find_value(keys, default, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} when is_integer(v) -> v
        _ -> nil
      end
    end)
  end

  defp float_field(map, keys, default) do
    Enum.find_value(keys, default, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} when is_number(v) -> v * 1.0
        _ -> nil
      end
    end)
  end
end
