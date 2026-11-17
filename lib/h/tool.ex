defmodule H.Tool do
  @moduledoc """
  Behaviour and JSON Schema validation helper for durable tools in `H`.
  """

  @type context :: %{
          required(:env) => H.ExecutionEnv.t(),
          required(:session_id) => String.t(),
          required(:conversation_id) => pos_integer(),
          optional(:task_id) => pos_integer(),
          optional(:scan_entries) => (map() -> {:ok, map()} | {:error, term()}),
          optional(:on_output) => (String.t(), non_neg_integer() -> any()),
          optional(:timeout_ms) => pos_integer()
        }

  @type tool_output :: %{
          content: [map()],
          details: map(),
          is_error: boolean(),
          diagnostic: nil | String.t()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback replay() :: :safe | :unsafe
  @callback mutating?() :: boolean()
  @callback execute(args :: map(), context()) :: {:ok, tool_output()} | {:error, tool_output()}

  @doc "Validates decoded JSON tool arguments against `tool_mod.parameters_schema/0` via cached `JSV` root."
  @spec validate_args(module(), term()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(tool_mod, args) when is_atom(tool_mod) do
    if is_map(args) do
      schema = tool_mod.parameters_schema()
      cache_key = {__MODULE__, tool_mod, :erlang.phash2(schema)}

      root =
        case :persistent_term.get(cache_key, nil) do
          nil ->
            built = JSV.build!(schema)
            :persistent_term.put(cache_key, built)
            built

          cached ->
            cached
        end

      case JSV.validate(args, root) do
        {:ok, validated} ->
          {:ok, validated}

        {:error, validation_error} ->
          {:error, Exception.message(validation_error)}
      end
    else
      {:error, "tool arguments must be a JSON object"}
    end
  end
end
