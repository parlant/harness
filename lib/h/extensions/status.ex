defmodule H.Extensions.Status do
  @moduledoc """
  Read-only extension status projection collector for
  `GET /api/v1/sessions/:sid/conversations/:cid/extension-status`.

  Projects cached, bounded scalar extension status maps for the active
  conversation and its configured model without performing provider I/O,
  creating atoms, or mutating transcript/cursor state.
  """

  @namespace_regex ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  @key_regex ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_keys 16
  @max_string_bytes 240
  @max_namespace_bytes 2_048
  @default_max_age_ms 5_000

  @doc """
  Collects and validates extension status projections for `scope`.

  `projections` is a list of `%{namespace: String.t(), module: module()}` specs
  (from startup-loaded extensions or daemon options). Any projection returning
  `:omit`, expired (`max_age_ms <= 0`), raising, timing out, or returning
  invalid/oversized data is omitted.
  """
  @spec project(
          %{
            session_id: String.t(),
            conversation_id: String.t(),
            model: nil | String.t()
          },
          [map()]
        ) :: map()
  def project(%{session_id: sid, conversation_id: cid, model: model} = scope, projections)
      when is_binary(sid) and is_binary(cid) and is_list(projections) do
    {extensions, min_ttl} =
      Enum.reduce(projections, {%{}, nil}, fn spec, {acc_ext, acc_ttl} ->
        with %{namespace: ns, module: mod} <- normalize_spec(spec),
             true <- valid_namespace?(ns),
             false <- Map.has_key?(acc_ext, ns),
             {:ok, data, ttl_ms} <- safe_call(mod, scope),
             {:ok, clean_data} <- validate_data(data) do
          next_ttl = if is_nil(acc_ttl), do: ttl_ms, else: min(acc_ttl, ttl_ms)
          {Map.put(acc_ext, ns, clean_data), next_ttl}
        else
          _ -> {acc_ext, acc_ttl}
        end
      end)

    %{
      "version" => 1,
      "session_id" => sid,
      "conversation_id" => cid,
      "model" => model,
      "max_age_ms" => min_ttl || @default_max_age_ms,
      "extensions" => extensions
    }
  end

  def project(scope, _projections) when is_map(scope) do
    project(scope, [])
  end

  @doc "Validates a status projection declaration at extension startup."
  @spec valid_spec?(term()) :: boolean()
  def valid_spec?(%{namespace: ns, module: mod} = spec)
      when map_size(spec) == 2 and is_atom(mod) do
    valid_namespace?(ns) and Code.ensure_loaded?(mod) and
      function_exported?(mod, :project, 1)
  end

  def valid_spec?(_), do: false

  @doc "Validates a projection namespace string."
  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(ns), do: is_binary(ns) and Regex.match?(@namespace_regex, ns)

  defp normalize_spec(%{namespace: ns, module: mod}), do: %{namespace: ns, module: mod}
  defp normalize_spec(_), do: nil

  defp safe_call(mod, scope) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :project, 1) do
      case mod.project(scope) do
        {:ok, data, ttl_ms} when is_map(data) and is_integer(ttl_ms) and ttl_ms > 0 ->
          {:ok, data, ttl_ms}

        _ ->
          :omit
      end
    else
      :omit
    end
  rescue
    _ -> :omit
  catch
    _, _ -> :omit
  end

  defp validate_data(data) when is_map(data) and map_size(data) <= @max_keys do
    cleaned =
      Enum.reduce_while(data, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        key = key_string(k)

        case {key, clean_scalar(v)} do
          {k_str, {:ok, clean_val}} when is_binary(k_str) ->
            {:cont, {:ok, Map.put(acc, k_str, clean_val)}}

          _ ->
            {:halt, :invalid}
        end
      end)

    with {:ok, map} <- cleaned,
         encoded when is_binary(encoded) <- JSON.encode!(map),
         true <- byte_size(encoded) <= @max_namespace_bytes do
      {:ok, map}
    else
      _ -> :invalid
    end
  rescue
    _ -> :invalid
  end

  defp validate_data(_), do: :invalid

  defp key_string(k) when is_atom(k) and k not in [nil, true, false],
    do: key_string(Atom.to_string(k))

  defp key_string(k) when is_binary(k) do
    if Regex.match?(@key_regex, k), do: k, else: nil
  end

  defp key_string(_), do: nil

  defp clean_scalar(v) when is_boolean(v) or is_integer(v) or is_nil(v), do: {:ok, v}

  defp clean_scalar(v) when is_float(v) do
    {:ok, v}
  end

  defp clean_scalar(v) when is_binary(v) do
    if String.valid?(v) do
      cleaned =
        v
        |> H.Credentials.sanitize()
        |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, @max_string_bytes)

      {:ok, cleaned}
    else
      :invalid
    end
  end

  defp clean_scalar(_), do: :invalid
end
