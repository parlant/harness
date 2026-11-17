defmodule H.Schema do
  @moduledoc """
  Boundary validator for untrusted decoded JSON maps, command envelopes,
  and HTTP parameters.

  Never calls `String.to_atom/1` on external input. Field specs define the exact
  permitted keys and types; keys are read by `Atom.to_string(key)` with fallback
  to existing atom keys for internal callers.
  """

  @session_id_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/
  @pos_int_regex ~r/^[0-9]+$/

  @type field_type ::
          :string
          | :non_empty_string
          | :id_string
          | :session_id
          | :abs_path
          | :boolean
          | :int
          | {:int, keyword()}
          | :pos_int
          | {:literal, term()}
          | {:enum, [term()]}
          | :map
          | {:map, [field_spec()]}
          | {:list, field_type()}
          | :any

  @type field_spec :: {atom(), field_type()} | {atom(), field_type(), keyword()}

  @doc """
  Validates an untrusted map against `field_specs`.

  Each spec is `{field_key, type}` or `{field_key, type, opts}` where `opts`
  supports `:required`, `:default`, and `:nullable`. Unknown keys in `input`
  are ignored and omitted from the returned atom-keyed map.
  """
  @spec validate_map(term(), [field_spec()]) :: {:ok, map()} | {:error, String.t()}
  def validate_map(input, field_specs) when is_map(input) and is_list(field_specs) do
    Enum.reduce_while(field_specs, {:ok, %{}}, fn spec, {:ok, acc} ->
      {key, type, opts} = normalize_spec(spec)
      key_str = Atom.to_string(key)

      case fetch_field(input, key, key_str) do
        :error ->
          handle_missing(acc, key, key_str, opts)

        {:ok, nil} ->
          if Keyword.get(opts, :nullable, false) do
            {:cont, {:ok, Map.put(acc, key, nil)}}
          else
            validate_and_put(acc, key, key_str, type, nil)
          end

        {:ok, value} ->
          validate_and_put(acc, key, key_str, type, value)
      end
    end)
  end

  def validate_map(_input, _field_specs), do: {:error, "expected a map"}

  @doc """
  Validates a session ID against `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`
  to prevent path traversal in session directories.
  """
  @spec validate_session_id(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_session_id(id) when is_binary(id) do
    if Regex.match?(@session_id_regex, id) do
      {:ok, id}
    else
      {:error, "invalid session_id"}
    end
  end

  def validate_session_id(_), do: {:error, "session_id must be a string"}

  @doc """
  Parses a positive integer from either an integer (`> 0`) or a base-10 digit string.
  """
  @spec parse_pos_int(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def parse_pos_int(val) when is_integer(val) and val > 0, do: {:ok, val}

  def parse_pos_int(val) when is_binary(val) do
    if Regex.match?(@pos_int_regex, val) do
      case String.to_integer(val) do
        n when n > 0 -> {:ok, n}
        _ -> {:error, "must be a positive integer"}
      end
    else
      {:error, "must be a positive integer"}
    end
  end

  def parse_pos_int(_), do: {:error, "must be a positive integer"}

  defp normalize_spec({key, type}) when is_atom(key), do: {key, type, []}

  defp normalize_spec({key, type, opts}) when is_atom(key) and is_list(opts),
    do: {key, type, opts}

  defp fetch_field(input, key, key_str) do
    case Map.fetch(input, key_str) do
      {:ok, _} = found -> found
      :error -> Map.fetch(input, key)
    end
  end

  defp handle_missing(acc, key, key_str, opts) do
    cond do
      Keyword.has_key?(opts, :default) ->
        {:cont, {:ok, Map.put(acc, key, Keyword.fetch!(opts, :default))}}

      Keyword.get(opts, :required, false) ->
        {:halt, {:error, "#{key_str} is required"}}

      true ->
        {:cont, {:ok, acc}}
    end
  end

  defp validate_and_put(acc, key, key_str, type, value) do
    case validate_value(type, value) do
      {:ok, validated} -> {:cont, {:ok, Map.put(acc, key, validated)}}
      {:error, reason} -> {:halt, {:error, "#{key_str}: #{reason}"}}
    end
  end

  defp validate_value(:string, value) when is_binary(value), do: {:ok, value}
  defp validate_value(:string, _), do: {:error, "must be a string"}

  defp validate_value(:non_empty_string, value) when is_binary(value) do
    if byte_size(String.trim(value)) > 0 do
      {:ok, value}
    else
      {:error, "must be a non-empty string"}
    end
  end

  defp validate_value(:non_empty_string, _), do: {:error, "must be a non-empty string"}

  defp validate_value(:id_string, value) when is_binary(value) do
    if Regex.match?(@session_id_regex, value) do
      {:ok, value}
    else
      {:error, "must be a valid id string"}
    end
  end

  defp validate_value(:id_string, _), do: {:error, "must be a valid id string"}

  defp validate_value(:session_id, value), do: validate_session_id(value)

  defp validate_value(:abs_path, value) when is_binary(value) do
    if Path.type(value) == :absolute do
      {:ok, value}
    else
      {:error, "must be an absolute path"}
    end
  end

  defp validate_value(:abs_path, _), do: {:error, "must be an absolute path"}

  defp validate_value(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp validate_value(:boolean, _), do: {:error, "must be a boolean"}

  defp validate_value(:int, value) when is_integer(value), do: {:ok, value}
  defp validate_value(:int, _), do: {:error, "must be an integer"}

  defp validate_value({:int, opts}, value) when is_integer(value) and is_list(opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      not is_nil(min) and value < min -> {:error, "must be >= #{min}"}
      not is_nil(max) and value > max -> {:error, "must be <= #{max}"}
      true -> {:ok, value}
    end
  end

  defp validate_value({:int, _opts}, _), do: {:error, "must be an integer"}

  defp validate_value(:pos_int, value), do: parse_pos_int(value)

  defp validate_value({:literal, expected}, value) do
    if value === expected do
      {:ok, value}
    else
      {:error, "must equal #{inspect(expected)}"}
    end
  end

  defp validate_value({:enum, allowed}, value) when is_list(allowed) do
    if value in allowed do
      {:ok, value}
    else
      {:error, "must be one of #{inspect(allowed)}"}
    end
  end

  defp validate_value(:map, value) when is_map(value), do: {:ok, value}
  defp validate_value(:map, _), do: {:error, "must be a map"}

  defp validate_value({:map, specs}, value) when is_map(value) and is_list(specs) do
    validate_map(value, specs)
  end

  defp validate_value({:map, _specs}, _), do: {:error, "must be a map"}

  defp validate_value({:list, item_type}, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, idx}, {:ok, acc} ->
      case validate_value(item_type, item) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, "item #{idx}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      err -> err
    end
  end

  defp validate_value({:list, _item_type}, _), do: {:error, "must be a list"}

  defp validate_value(:any, value), do: {:ok, value}
end
