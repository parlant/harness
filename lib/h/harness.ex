defmodule H.Harness do
  @moduledoc """
  Behaviour for pluggable agent harness profiles (`H.Harness.Coding`, etc.).

  A harness defines the profile descriptor, tool modules, and workspace context
  bootstrapping (such as `AGENTS.md` discovery through `H.ExecutionEnv`).
  """

  alias H.ExecutionEnv

  @type descriptor :: %{
          id: String.t(),
          name: String.t(),
          description: String.t()
        }

  @callback id() :: String.t()
  @callback descriptor() :: descriptor()
  @callback tools(opts :: keyword()) :: [module()]
  @callback bootstrap_agent(ExecutionEnv.t(), overrides :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @default_harnesses %{
    "coding" => H.Harness.Coding,
    "pi" => H.Harness.Coding
  }

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
end
