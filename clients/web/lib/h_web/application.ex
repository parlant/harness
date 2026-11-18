defmodule HWeb.Application do
  @moduledoc """
  OTP application entry point for `:harness_web`.

  Depends on `:harness` so `:harness` boots before `HWeb.Endpoint`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
