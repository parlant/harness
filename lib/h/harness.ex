defmodule H.Harness do
  @moduledoc """
  Behaviour for pluggable agent harness profiles (`H.Harness.Coding`, etc.).

  A harness defines the profile descriptor, tool modules, and workspace context
  bootstrapping (such as `AGENTS.md` discovery through `H.ExecutionEnv`).
  Follow [Author a harness profile on hiness.dev](https://hiness.dev/docs/extensions/#author-a-harness-profile)
  to register a custom profile.
  """

  alias H.ExecutionEnv

  @type descriptor :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          optional(:aliases) => [String.t()]
        }

  @type context_projection :: %{
          required(:session_id) => String.t(),
          required(:conversation_id) => pos_integer(),
          required(:purpose) => :generation | :compaction,
          required(:agent) => map(),
          required(:request) => map()
        }

  @type context_contribution :: %{
          optional(:prepend_system) => String.t() | [String.t()],
          optional(:append_system) => String.t() | [String.t()],
          optional(:ephemeral_context) => String.t() | [String.t()]
        }

  @type response_scope :: %{
          required(:session_id) => String.t(),
          required(:conversation_id) => pos_integer(),
          required(:model) => nil | String.t(),
          required(:finish_reason) => String.t()
        }

  @callback id() :: String.t()
  @callback descriptor() :: descriptor()
  @callback tools(opts :: keyword()) :: [module()]
  @callback bootstrap_agent(ExecutionEnv.t(), overrides :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback prepare_context(context_projection(), opts :: keyword()) ::
              {:ok, context_contribution()} | {:error, term()}
  @callback project_response(response :: map(), response_scope()) ::
              :ignore | {:ok, map()}

  @optional_callbacks [prepare_context: 2, project_response: 2]

  @default_harnesses %{
    "coding" => H.Harness.Coding,
    "pi" => H.Harness.Coding
  }

  @max_context_bytes 32_768
  @max_annotation_bytes 4_096

  @doc """
  Lists configured harness profile descriptors (`"coding"` first, followed by
  custom profiles sorted by canonical ID, with aliases collapsed onto `"coding"`).
  """
  @spec list_harnesses(keyword()) :: [map()]
  def list_harnesses(opts \\ []) when is_list(opts) do
    registry = build_registry(Keyword.get(opts, :harnesses))

    {by_mod, aliases_by_mod} =
      Enum.reduce(registry, {%{}, %{}}, fn {key, mod}, {mods, aliases} ->
        canonical_id = safe_canonical_id(mod, key)

        if key == canonical_id do
          {Map.put(mods, mod, canonical_id), aliases}
        else
          {Map.put_new(mods, mod, canonical_id), Map.update(aliases, mod, [key], &[key | &1])}
        end
      end)

    by_mod
    |> Enum.map(fn {mod, canonical_id} ->
      desc = mod.descriptor()
      alias_list = aliases_by_mod |> Map.get(mod, []) |> Enum.uniq() |> Enum.sort()

      base = %{
        "id" => to_string(Map.get(desc, :id) || Map.get(desc, "id") || canonical_id),
        "name" => to_string(Map.get(desc, :name) || Map.get(desc, "name") || canonical_id),
        "description" =>
          to_string(Map.get(desc, :description) || Map.get(desc, "description") || "")
      }

      if alias_list == [], do: base, else: Map.put(base, "aliases", alias_list)
    end)
    |> Enum.sort_by(fn desc -> {desc["id"] != "coding", desc["id"]} end)
  end

  @doc """
  Invokes an optional `prepare_context/2` callback for `harness_mod` and applies
  validated, bounded context contributions to `request`.

  Fails closed (`{:error, %{code: "context_preparation_failed", ...}}`) on
  callback error, timeout, raise, exit, invalid contribution shape, or budget
  overflow (> 32 KiB total UTF-8 contribution).
  """
  @spec apply_prepare_context(module(), context_projection(), map(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def apply_prepare_context(harness_mod, projection, request, opts \\ [])
      when is_atom(harness_mod) and is_map(projection) and is_map(request) and is_list(opts) do
    if Code.ensure_loaded?(harness_mod) and function_exported?(harness_mod, :prepare_context, 2) do
      case safe_prepare_context(harness_mod, projection, opts) do
        {:ok, contribution} ->
          with {:ok, validated} <- validate_context_contribution(contribution) do
            {:ok, merge_context_contribution(request, validated)}
          end

        {:error, reason} ->
          {:error, context_preparation_error(reason)}
      end
    else
      {:ok, request}
    end
  end

  @doc """
  Invokes an optional `project_response/2` callback for `harness_mod`, returning
  either `:ignore` or `{:ok, sanitized_json_safe_map}` (<= 4 KiB).

  Errors, invalid shapes, or oversized payloads are safely ignored (`:ignore`).
  """
  @spec safe_project_response(module(), map(), response_scope()) :: :ignore | {:ok, map()}
  def safe_project_response(harness_mod, response, scope)
      when is_atom(harness_mod) and is_map(response) and is_map(scope) do
    if Code.ensure_loaded?(harness_mod) and function_exported?(harness_mod, :project_response, 2) do
      try do
        case harness_mod.project_response(response, scope) do
          {:ok, annotation} when is_map(annotation) ->
            sanitize_annotation(annotation)

          _ ->
            :ignore
        end
      rescue
        _ -> :ignore
      catch
        _, _ -> :ignore
      end
    else
      :ignore
    end
  end

  def safe_project_response(_harness_mod, _response, _scope), do: :ignore

  @doc """
  Resolves a harness module from a string ID (defaulting `nil` to `H.Harness.Coding`).

  Supports custom registrations via `opts[:harnesses]` as either a `%{id => module}`
  map or a list of `H.Harness` modules. Never creates atoms from input.
  """
  @spec resolve(nil | String.t(), keyword()) :: {:ok, module()} | {:error, :unknown_harness}
  def resolve(harness_id_or_nil, opts \\ []) when is_list(opts) do
    registry = build_registry(Keyword.get(opts, :harnesses))
    key = if is_nil(harness_id_or_nil), do: "coding", else: harness_id_or_nil

    if is_binary(key) do
      case Map.fetch(registry, key) do
        {:ok, mod} when is_atom(mod) -> {:ok, mod}
        _ -> {:error, :unknown_harness}
      end
    else
      {:error, :unknown_harness}
    end
  end

  defp build_registry(nil), do: @default_harnesses

  defp build_registry(harnesses) when is_map(harnesses) do
    Enum.reduce(harnesses, @default_harnesses, fn
      {id, mod}, acc when is_binary(id) and is_atom(mod) -> Map.put(acc, id, mod)
      _, acc -> acc
    end)
  end

  defp build_registry(harnesses) when is_list(harnesses) do
    Enum.reduce(harnesses, @default_harnesses, fn
      mod, acc when is_atom(mod) -> Map.put(acc, mod.id(), mod)
      _, acc -> acc
    end)
  end

  defp safe_canonical_id(mod, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :id, 0) do
      mod.id()
    else
      fallback
    end
  end

  defp safe_prepare_context(harness_mod, projection, opts) do
    timeout_ms =
      case Keyword.get(opts, :prepare_context_timeout_ms, 5_000) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> 5_000
      end

    caller = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        res =
          try do
            harness_mod.prepare_context(projection, opts)
          rescue
            e -> {:error, {:exception, Exception.message(e)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(caller, {:prepare_context_done, ref, res})
      end)

    receive do
      {:prepare_context_done, ^ref, {:ok, contribution}} ->
        Process.demonitor(mon, [:flush])
        {:ok, contribution}

      {:prepare_context_done, ^ref, {:error, reason}} ->
        Process.demonitor(mon, [:flush])
        {:error, reason}

      {:prepare_context_done, ^ref, other} ->
        Process.demonitor(mon, [:flush])
        {:error, {:invalid_return, other}}

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:error, {:crashed, reason}}
    after
      timeout_ms ->
        Process.demonitor(mon, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp validate_context_contribution(contrib) when is_map(contrib) do
    allowed_keys = [:prepend_system, :append_system, :ephemeral_context]

    with [] <- Map.keys(contrib) -- allowed_keys,
         {:ok, prepend} <- normalize_text_list(Map.get(contrib, :prepend_system)),
         {:ok, append} <- normalize_text_list(Map.get(contrib, :append_system)),
         {:ok, ephemeral} <- normalize_text_list(Map.get(contrib, :ephemeral_context)),
         total_bytes =
           Enum.sum(Enum.map(prepend ++ append ++ ephemeral, &byte_size/1)),
         true <- total_bytes <= @max_context_bytes do
      {:ok, %{prepend_system: prepend, append_system: append, ephemeral_context: ephemeral}}
    else
      false ->
        {:error, context_preparation_error(:context_budget_exceeded)}

      _ ->
        {:error, context_preparation_error(:invalid_contribution)}
    end
  end

  defp validate_context_contribution(_),
    do: {:error, context_preparation_error(:invalid_contribution)}

  defp normalize_text_list(nil), do: {:ok, []}

  defp normalize_text_list(text) when is_binary(text) do
    if String.valid?(text) do
      if text == "", do: {:ok, []}, else: {:ok, [text]}
    else
      {:error, :invalid_utf8}
    end
  end

  defp normalize_text_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      item, {:ok, acc} when is_binary(item) ->
        if String.valid?(item) do
          if item == "", do: {:cont, {:ok, acc}}, else: {:cont, {:ok, [item | acc]}}
        else
          {:halt, {:error, :invalid_utf8}}
        end

      _, _ ->
        {:halt, {:error, :invalid_text_item}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp normalize_text_list(_), do: {:error, :invalid_text_item}

  defp merge_context_contribution(
         request,
         %{prepend_system: [], append_system: [], ephemeral_context: []}
       ),
       do: request

  defp merge_context_contribution(request, %{
         prepend_system: prepend,
         append_system: append,
         ephemeral_context: ephemeral
       }) do
    messages = Map.get(request, :messages, [])
    messages = update_system_messages(messages, prepend, append)

    messages =
      if ephemeral == [] do
        messages
      else
        ephemeral_msg = %{
          role: "user",
          content: Enum.map(ephemeral, &%{type: "text", text: &1})
        }

        messages ++ [ephemeral_msg]
      end

    Map.put(request, :messages, messages)
  end

  defp update_system_messages(messages, [], []), do: messages

  defp update_system_messages(messages, prepend, append) do
    prepend_text = Enum.join(prepend, "\n\n")
    append_text = Enum.join(append, "\n\n")

    case messages do
      [%{role: "system", content: content} = first | rest] ->
        existing =
          content
          |> Enum.flat_map(fn
            %{type: "text", text: t} when is_binary(t) and t != "" -> [t]
            _ -> []
          end)

        parts =
          ([prepend_text | existing] ++ [append_text])
          |> Enum.reject(&(&1 == ""))

        updated_first = %{first | content: [%{type: "text", text: Enum.join(parts, "\n\n")}]}
        [updated_first | rest]

      other ->
        parts = [prepend_text, append_text] |> Enum.reject(&(&1 == ""))

        if parts == [] do
          other
        else
          [%{role: "system", content: [%{type: "text", text: Enum.join(parts, "\n\n")}]} | other]
        end
    end
  end

  defp context_preparation_error(reason) do
    detail =
      case reason do
        :timeout -> "Context preparation timed out."
        :context_budget_exceeded -> "Prepared context exceeds 32 KiB budget."
        :invalid_contribution -> "Harness returned an invalid context contribution."
        other -> "Context preparation failed (#{inspect(other)})."
      end

    %{
      code: "context_preparation_failed",
      message: H.Credentials.sanitize(detail),
      retryable: false
    }
  end

  defp sanitize_annotation(map) when is_map(map) do
    sanitized = sanitize_json_value(map)

    if is_map(sanitized) and map_size(sanitized) > 0 do
      encoded = JSON.encode!(sanitized)

      if byte_size(encoded) <= @max_annotation_bytes do
        {:ok, sanitized}
      else
        :ignore
      end
    else
      :ignore
    end
  rescue
    _ -> :ignore
  end

  defp sanitize_json_value(val) when is_struct(val),
    do: val |> Map.from_struct() |> sanitize_json_value()

  defp sanitize_json_value(val) when is_map(val) do
    Enum.reduce(val, %{}, fn {k, v}, acc ->
      case sanitize_json_value(v) do
        :drop -> acc
        clean_v -> Map.put(acc, to_string(k), clean_v)
      end
    end)
  end

  defp sanitize_json_value(val) when is_list(val) do
    val
    |> Enum.map(&sanitize_json_value/1)
    |> Enum.reject(&(&1 == :drop))
  end

  defp sanitize_json_value(val) when is_binary(val) do
    if String.valid?(val), do: H.Credentials.sanitize(val), else: :drop
  end

  defp sanitize_json_value(val)
       when is_boolean(val) or is_integer(val) or is_float(val) or is_nil(val),
       do: val

  defp sanitize_json_value(val) when is_atom(val), do: Atom.to_string(val)
  defp sanitize_json_value(_), do: :drop
end
