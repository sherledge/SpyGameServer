defmodule SpyGameServerWeb.UserSocket do
  use Phoenix.Socket
  channel "drawful:*", SpyGameServerWeb.DrawfulChannel
  channel "lobby:*", SpyGameServerWeb.LobbyChannel
  channel "spyword:*", SpyGameServerWeb.GameChannel
  channel "fibbage:*", SpyGameServerWeb.FibbageChannel
  channel "wordle:*", SpyGameServerWeb.WordleChannel
  @impl true
  def connect(_params, socket, _connect_info) do
    # Assign a dummy or parsed user id so assigns never crashes
    {:ok, assign(socket, :user_id, Ecto.UUID.generate())}
  end

  @impl true
  def id(_socket), do: nil
end
