defmodule HWeb.Application do
  @moduledoc """
  OTP application entry point for `:harness_web`.

  Depends on `:harness` so `:harness` boots before `HWeb.Endpoint`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    HWeb.Backend.HTTP.configure_from_env()

    children = [
      {Phoenix.PubSub, name: HWeb.PubSub},
      {Registry, keys: :unique, name: HWeb.Backend.HTTP.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: HWeb.Backend.HTTP.SSESupervisor},
      HWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HWeb.Supervisor]
    Supervisor.start_link(children ++ HWeb.Standalone.listeners(), opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
