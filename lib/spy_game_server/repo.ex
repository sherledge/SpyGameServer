defmodule SpyGameServer.Repo do
  use Ecto.Repo,
    otp_app: :spy_game_server,
    adapter: Ecto.Adapters.Postgres
end
