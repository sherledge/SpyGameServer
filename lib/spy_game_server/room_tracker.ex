defmodule SpyGameServer.RoomTracker do
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get_all(game_id) do
    Agent.get(__MODULE__, fn rooms ->
      rooms
      |> Map.values()
      |> Enum.filter(&(&1.gameId == game_id))
    end)
  end

  def get_room(code), do: Agent.get(__MODULE__, &Map.get(&1, code))

  def create_room(player_name, user_id, game_id) do
    code = :crypto.strong_rand_bytes(3) |> Base.encode16()

    room = %{
      id: code,
      name: "Room #{code}",
      players: 1,
      hostId: user_id,
      members: [user_id],
      playerNames: %{user_id => player_name},
      gameData: nil,
      gameId: game_id
    }

    Agent.update(__MODULE__, &Map.put(&1, code, room))
    room
  end

  def add_member(code, user_id, player_name, game_id) do
    Agent.get_and_update(__MODULE__, fn rooms ->
      case Map.get(rooms, code) do
        nil ->
          {{:error, :not_found}, rooms}

        room ->
          cond do
            room.gameId != game_id ->
              {{:error, :wrong_game}, rooms}

            user_id in room.members ->
              {{:ok, room}, rooms}

            length(room.members) >= 5 ->
              {{:error, :full}, rooms}

            true ->
              updated_members = room.members ++ [user_id]
              updated = %{
                room
                | members: updated_members,
                  playerNames: Map.put(room.playerNames, user_id, player_name),
                  players: length(updated_members)
              }

              {{:ok, updated}, Map.put(rooms, code, updated)}
          end
      end
    end)
  end

  def update_game_data(code, fun) do
  Agent.update(__MODULE__, fn rooms ->
    case Map.get(rooms, code) do
      nil -> rooms
      room -> Map.put(rooms, code, %{room | gameData: fun.(room.gameData)})
    end
  end)
end

  def set_game_data(code, game_data) do
    Agent.update(__MODULE__, fn rooms ->
      case Map.get(rooms, code) do
        nil -> rooms
        room -> Map.put(rooms, code, %{room | gameData: game_data})
      end
    end)
  end

  def record_vote(code, target_id) do
    Agent.get_and_update(__MODULE__, fn rooms ->
      case Map.get(rooms, code) do
        %{gameData: nil} ->
          {{:error, :no_game}, rooms}

        nil ->
          {{:error, :not_found}, rooms}

        room ->
          gd = room.gameData
          votes = Map.update(gd.votes, target_id, 1, &(&1 + 1))
          new_gd = %{gd | votes: votes, votedCount: gd.votedCount + 1}
          updated_room = %{room | gameData: new_gd}
          {{:ok, new_gd}, Map.put(rooms, code, updated_room)}
      end
    end)
  end

  def delete_room(code), do: Agent.update(__MODULE__, &Map.delete(&1, code))
end
