defmodule SpyGameServerWeb.LobbyChannel do
  use SpyGameServerWeb, :channel
  alias SpyGameServer.RoomTracker

  @impl true
  def join("lobby:" <> game_id, payload, socket) do
    IO.inspect(payload, label: "--- RECEIVED PHX_JOIN PAYLOAD ---")

    socket =
      socket
      |> assign(:user_id, socket.assigns[:user_id] || Ecto.UUID.generate())
      |> assign(:game_id, game_id)

    send(self(), :after_join)

    {:ok, %{userId: socket.assigns.user_id}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "update_room_list", %{rooms: sanitize_rooms(RoomTracker.get_all(socket.assigns.game_id))})
    {:noreply, socket}
  end

  @impl true
  def handle_in("get_room_list", _payload, socket) do
    {:reply, {:ok, %{rooms: sanitize_rooms(RoomTracker.get_all(socket.assigns.game_id))}}, socket}
  end

  @impl true
  def handle_in("create_room", payload, socket) do
    data = payload["Element"] || payload
    player_name = data["playerName"] || data["player_name"] || "Player"
    game_id = socket.assigns.game_id

    room = RoomTracker.create_room(player_name, socket.assigns.user_id, game_id)
    broadcast!(socket, "update_room_list", %{rooms: sanitize_rooms(RoomTracker.get_all(game_id))})

    {:reply, {:ok, %{roomCode: room.id}}, socket}
  end

@impl true
def handle_in("join_room", payload, socket) do
  data = payload["Element"] || payload
  room_code = data["roomCode"] || data["room_code"]
  player_name = data["playerName"] || data["player_name"] || "Player"
  game_id = socket.assigns.game_id

  case RoomTracker.add_member(room_code, socket.assigns.user_id, player_name, game_id) do
    {:ok, room} ->
      players = player_list(room)
      SpyGameServerWeb.Endpoint.broadcast("#{room_channel_prefix(room.gameId)}:#{room_code}", "room_players_updated", %{players: players})
      broadcast!(socket, "update_room_list", %{rooms: sanitize_rooms(RoomTracker.get_all(game_id))})
      {:reply, {:ok, %{roomCode: room_code, players: players}}, socket}

    {:error, :not_found} ->
      {:reply, {:error, %{reason: "Room does not exist!"}}, socket}

    {:error, :full} ->
      {:reply, {:error, %{reason: "Room Full!"}}, socket}

    {:error, :wrong_game} ->
      {:reply, {:error, %{reason: "That room belongs to a different game!"}}, socket}
  end
end

# Maps a game's id to its actual room-channel topic prefix. Spyword is
# grandfathered onto the plain "room" prefix from before this became
# multi-game; every game added after this should just use its own gameId
# as the prefix directly, so this map should rarely need new entries.
defp room_channel_prefix("drawful"), do: "drawful"
defp room_channel_prefix(_spyword_or_default), do: "room"

  defp player_list(room) do
    Enum.map(room.members, fn id ->
      %{id: id, name: Map.get(room.playerNames, id, "Player")}
    end)
  end

  defp sanitize_rooms(rooms) do
    Enum.map(rooms, fn room ->
      %{id: room.id, name: room.name, players: room.players}
    end)
  end
end
