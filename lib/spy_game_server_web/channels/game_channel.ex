defmodule SpyGameServerWeb.GameChannel do
  use SpyGameServerWeb, :channel
  alias SpyGameServer.RoomTracker

  @impl true
  def join("spyword:" <> room_code, _payload, socket) do
    case RoomTracker.get_room(room_code) do
      nil ->
        {:error, %{reason: "Room does not exist!"}}

      _room ->
        user_id = socket.assigns.user_id
        Phoenix.PubSub.subscribe(SpyGameServer.PubSub, "spyword:#{room_code}:#{user_id}")
        socket = assign(socket, :room_code, room_code)
        send(self(), :after_join)
        {:ok, socket}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case RoomTracker.get_room(socket.assigns.room_code) do
      nil ->
        {:noreply, socket}

      room ->
        push(socket, "room_players_updated", %{players: player_list(room)})
        {:noreply, socket}
    end
  end

  def handle_info({:personal, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("start_game", _payload, socket) do
    room_code = socket.assigns.room_code
    room = RoomTracker.get_room(room_code)

    cond do
      room == nil ->
        {:reply, {:error, %{reason: "Room does not exist!"}}, socket}

      length(room.members) < 3 ->
        {:reply, {:error, %{reason: "Minimum 3 players required!"}}, socket}

      true ->
        spy_id = Enum.random(room.members)
        word = select_random_word()
        vivox_chan = "vivox_" <> String.downcase(room_code)

        game_data = %{
          spy: spy_id,
          word: word,
          turnsOrder: room.members,
          currentTurnIndex: 0,
          votes: %{},
          votedCount: 0
        }

        RoomTracker.set_game_data(room_code, game_data)

        Enum.each(room.members, fn member_id ->
          is_spy = member_id == spy_id

          payload = %{
            role: if(is_spy, do: "Varathan", else: "Nattukar"),
            word: if(is_spy, do: "", else: word),
            playerName: Map.get(room.playerNames, member_id, "Player"),
            vivoxChannel: vivox_chan
          }

          Phoenix.PubSub.broadcast(
            SpyGameServer.PubSub,
            "spyword:#{room_code}:#{member_id}",
            {:personal, "game_started_init", payload}
          )
        end)

        Task.start(fn -> run_game_flow(room_code) end)
        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("player_speaking_changed", %{"isSpeaking" => is_speaking}, socket) do
    SpyGameServerWeb.Endpoint.broadcast("spyword:#{socket.assigns.room_code}", "player_speaking_updated", %{
      playerId: socket.assigns.user_id,
      isSpeaking: is_speaking
    })
    {:noreply, socket}
  end

  @impl true
  def handle_in("submit_vote", %{"targetId" => target_id}, socket) do
    room_code = socket.assigns.room_code

    case RoomTracker.record_vote(room_code, target_id) do
      {:ok, game_data} ->
        if game_data.votedCount >= length(game_data.turnsOrder) do
          evaluate_votes(room_code, RoomTracker.get_room(room_code), game_data)
        end
        {:reply, :ok, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "No active game"}}, socket}
    end
  end

  @impl true
  def handle_in("request_room_sync", _payload, socket) do
    case RoomTracker.get_room(socket.assigns.room_code) do
      nil ->
        {:noreply, socket}

      room ->
        push(socket, "room_players_updated", %{players: player_list(room)})
        {:noreply, socket}
    end
  end

  # --- Private helpers ---

  defp select_random_word do
    path = Application.app_dir(:spy_game_server, "priv/words.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, words} when is_list(words) and length(words) > 0 ->
            Enum.random(words)

          _ ->
            "Apple"
        end

      {:error, _reason} ->
        "Apple"
    end
  end

  defp player_list(room) do
    Enum.map(room.members, fn id -> %{id: id, name: Map.get(room.playerNames, id, "Player")} end)
  end

  defp run_game_flow(room_code) do
    Process.sleep(2000)

    case RoomTracker.get_room(room_code) do
      %{gameData: %{turnsOrder: turns}} -> run_turns(room_code, turns, 0)
      _ -> :ok
    end
  end

  defp run_turns(room_code, turns_order, index) when index < length(turns_order) do
    room = RoomTracker.get_room(room_code)
    speaker_id = Enum.at(turns_order, index)
    speaker_name = if room, do: Map.get(room.playerNames, speaker_id, "Player"), else: "Player"

    SpyGameServerWeb.Endpoint.broadcast("spyword:#{room_code}", "turn_changed", %{
      speakerId: speaker_id,
      speakerName: speaker_name,
      duration: 15
    })

    Process.sleep(15500)
    run_turns(room_code, turns_order, index + 1)
  end

  defp run_turns(room_code, _turns_order, _index) do
    SpyGameServerWeb.Endpoint.broadcast("spyword:#{room_code}", "discussion_phase_start", %{duration: 60})
    Process.sleep(60_000)
    SpyGameServerWeb.Endpoint.broadcast("spyword:#{room_code}", "voting_phase_start", %{})
  end

  defp evaluate_votes(room_code, room, game_data) do
    {voted_out_id, _highest, tie?} =
      Enum.reduce(game_data.votes, {nil, 0, false}, fn {player, count}, {cur_id, cur_max, _tie} ->
        cond do
          count > cur_max -> {player, count, false}
          count == cur_max and cur_max > 0 -> {cur_id, cur_max, true}
          true -> {cur_id, cur_max, false}
        end
      end)

    spy_name = Map.get(room.playerNames, game_data.spy, "Spy")

    citizen_names =
      room.members
      |> Enum.reject(&(&1 == game_data.spy))
      |> Enum.map(&Map.get(room.playerNames, &1, "Citizen"))
      |> Enum.join(", ")

    {message, winners} =
      cond do
        tie? ->
          {"Votes tied! Spy escaped! Spy was #{spy_name}.", spy_name}

        voted_out_id != game_data.spy ->
          voted_name = Map.get(room.playerNames, voted_out_id, "Wrong Player")
          {"Wrong player voted out (#{voted_name})! Spy Won. Spy was #{spy_name}.", spy_name}

        true ->
          {"Spy was caught! Spy was #{spy_name}.", citizen_names}
      end

    SpyGameServerWeb.Endpoint.broadcast("spyword:#{room_code}", "game_over", %{
      message: message,
      winners: winners,
      spyName: spy_name
    })

    RoomTracker.delete_room(room_code)

    SpyGameServerWeb.Endpoint.broadcast("lobby:#{room.gameId}", "update_room_list", %{
      rooms: RoomTracker.get_all(room.gameId)
    })
  end
end
