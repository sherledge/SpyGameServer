defmodule SpyGameServer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SpyGameServerWeb.Telemetry,
      #SpyGameServer.Repo,
      {DNSCluster, query: Application.get_env(:spy_game_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SpyGameServer.PubSub},
      SpyGameServer.RoomTracker,
      # Start a worker by calling: SpyGameServer.Worker.start_link(arg)
      # {SpyGameServer.Worker, arg},
      # Start to serve requests, typically the last entry
      SpyGameServerWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SpyGameServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SpyGameServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
