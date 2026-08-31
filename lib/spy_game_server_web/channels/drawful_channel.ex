defmodule SpyGameServerWeb.DrawfulChannel do
  use SpyGameServerWeb, :channel
  alias SpyGameServer.RoomTracker

  @impl true
  def join("drawful:" <> room_code, _payload, socket) do
    case RoomTracker.get_room(room_code) do
      nil ->
        {:error, %{reason: "Room does not exist!"}}

      _room ->
        user_id = socket.assigns.user_id
        Phoenix.PubSub.subscribe(SpyGameServer.PubSub, "drawful:#{room_code}:#{user_id}")
        socket = assign(socket, :room_code, room_code)
        send(self(), :after_join)
        {:ok, socket}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case RoomTracker.get_room(socket.assigns.room_code) do
      nil -> {:noreply, socket}
      room -> push(socket, "room_players_updated", %{players: player_list(room)}); {:noreply, socket}
    end
  end

  def handle_info({:personal, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("request_room_sync", _payload, socket) do
    case RoomTracker.get_room(socket.assigns.room_code) do
      nil -> {:noreply, socket}
      room -> push(socket, "room_players_updated", %{players: player_list(room)}); {:noreply, socket}
    end
  end

  @impl true
  def handle_in("start_game", _payload, socket) do
    room_code = socket.assigns.room_code
    room = RoomTracker.get_room(room_code)

    cond do
      room == nil ->
        {:reply, {:error, %{reason: "Room does not exist!"}}, socket}

      length(room.members) < 2 ->
        {:reply, {:error, %{reason: "Minimum 2 players required!"}}, socket}

      true ->
        prompts = load_prompts()
        prompt_map = Enum.into(room.members, %{}, fn id -> {id, Enum.random(prompts)} end)

        game_data = %{
          drawers: room.members,
          prompts: prompt_map,
          drawings: %{},
          scores: Enum.into(room.members, %{}, fn id -> {id, 0} end),
          currentIndex: 0,
          currentOwnerId: nil,
          answers: %{},
          votes: %{}
        }

        RoomTracker.set_game_data(room_code, game_data)

        Enum.each(room.members, fn member_id ->
          payload = %{prompt: Map.get(prompt_map, member_id), duration: 30}
          Phoenix.PubSub.broadcast(
            SpyGameServer.PubSub,
            "drawful:#{room_code}:#{member_id}",
            {:personal, "drawing_phase_start", payload}
          )
        end)

        Task.start(fn -> run_game_flow(room_code) end)
        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("submit_drawing", %{"imageData" => data}, socket) do
    RoomTracker.update_game_data(socket.assigns.room_code, fn gd ->
      %{gd | drawings: Map.put(gd.drawings, socket.assigns.user_id, data)}
    end)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("submit_answer", %{"text" => text}, socket) do
    RoomTracker.update_game_data(socket.assigns.room_code, fn gd ->
      if gd != nil and socket.assigns.user_id != gd.currentOwnerId do
        %{gd | answers: Map.put(gd.answers, socket.assigns.user_id, text)}
      else
        gd
      end
    end)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("submit_guess_vote", %{"targetOwnerId" => target_id}, socket) do
    RoomTracker.update_game_data(socket.assigns.room_code, fn gd ->
      if gd != nil and socket.assigns.user_id != gd.currentOwnerId do
        %{gd | votes: Map.put(gd.votes, socket.assigns.user_id, target_id)}
      else
        gd
      end
    end)
    {:reply, :ok, socket}
  end

  defp player_list(room) do
    Enum.map(room.members, fn id -> %{id: id, name: Map.get(room.playerNames, id, "Player")} end)
  end

  defp load_prompts do
    path = Application.app_dir(:spy_game_server, "priv/drawful_prompts.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) and length(list) > 0 -> list
          _ -> ["A cat riding a skateboard"]
        end

      _ ->
        ["A cat riding a skateboard"]
    end
  end

  # --- Game flow ---

  defp run_game_flow(room_code) do
    # Buffer beyond the 30s client countdown so late drawings still land.
    Process.sleep(30_500)
    room = RoomTracker.get_room(room_code)
    run_drawing_round(room_code, room.gameData.drawers, 0)
  end

  defp run_drawing_round(room_code, drawer_ids, index) when index < length(drawer_ids) do
    owner_id = Enum.at(drawer_ids, index)
    room = RoomTracker.get_room(room_code)
    gd = room.gameData
    drawer_name = Map.get(room.playerNames, owner_id, "Player")
    image_data = Map.get(gd.drawings, owner_id, "")
    correct_text = Map.get(gd.prompts, owner_id, "")

    RoomTracker.update_game_data(room_code, fn g ->
      %{g | currentIndex: index, currentOwnerId: owner_id, answers: %{}, votes: %{}}
    end)

    SpyGameServerWeb.Endpoint.broadcast("drawful:#{room_code}", "reveal_drawing", %{
      ownerId: owner_id, ownerName: drawer_name, imageData: image_data
    })

    Process.sleep(3_000)

    SpyGameServerWeb.Endpoint.broadcast("drawful:#{room_code}", "answer_phase_start", %{duration: 20})
    Process.sleep(20_500)

    room2 = RoomTracker.get_room(room_code)
    gd2 = room2.gameData

    choices =
      (Enum.map(gd2.answers, fn {writer_id, text} -> %{ownerId: writer_id, text: text} end) ++
         [%{ownerId: "TRUTH", text: correct_text}])
      |> Enum.shuffle()

    SpyGameServerWeb.Endpoint.broadcast("drawful:#{room_code}", "voting_phase_start", %{
      choices: choices, duration: 20
    })
    Process.sleep(20_500)

    room3 = RoomTracker.get_room(room_code)
    reveal_and_score(room_code, room3, room3.gameData, owner_id, choices)

    run_drawing_round(room_code, drawer_ids, index + 1)
  end

  defp run_drawing_round(room_code, _drawer_ids, _index) do
    room = RoomTracker.get_room(room_code)
    gd = room.gameData

    final_scores =
      gd.scores
      |> Enum.map(fn {id, score} -> %{name: Map.get(room.playerNames, id, "Player"), score: score} end)
      |> Enum.sort_by(& &1.score, :desc)

    SpyGameServerWeb.Endpoint.broadcast("drawful:#{room_code}", "game_over", %{scores: final_scores})

    RoomTracker.delete_room(room_code)
    SpyGameServerWeb.Endpoint.broadcast("lobby:#{room.gameId}", "update_room_list", %{
      rooms: RoomTracker.get_all(room.gameId)
    })
  end

  defp reveal_and_score(room_code, room, gd, owner_id, choices) do
    vote_counts =
      Enum.reduce(gd.votes, %{}, fn {_voter, target}, acc -> Map.update(acc, target, 1, &(&1 + 1)) end)

    voter_names_by_target =
      Enum.reduce(gd.votes, %{}, fn {voter_id, target}, acc ->
        name = Map.get(room.playerNames, voter_id, "Player")
        Map.update(acc, target, [name], &(&1 ++ [name]))
      end)

    # Skip zero-vote answers, reveal least → most voted.
    choices
    |> Enum.filter(fn c -> Map.get(vote_counts, c.ownerId, 0) > 0 end)
    |> Enum.sort_by(fn c -> Map.get(vote_counts, c.ownerId, 0) end)
    |> Enum.each(fn c ->
      is_correct = c.ownerId == "TRUTH"

      SpyGameServerWeb.Endpoint.broadcast("drawful:#{room_code}", "reveal_vote_result", %{
        text: c.text,
        isCorrect: is_correct,
        ownerName: if(is_correct, do: "Correct Answer", else: Map.get(room.playerNames, c.ownerId, "Player")),
        voteCount: Map.get(vote_counts, c.ownerId, 0),
        voterNames: Map.get(voter_names_by_target, c.ownerId, [])
      })

      Process.sleep(2_500)
    end)

    correct_votes = Map.get(vote_counts, "TRUTH", 0)

    new_scores =
      Enum.reduce(gd.votes, gd.scores, fn {voter_id, target}, scores ->
        if target == "TRUTH" do
          Map.update(scores, voter_id, 100, &(&1 + 100))
        else
          Map.update(scores, target, 50, &(&1 + 50))
        end
      end)

    new_scores =
      if correct_votes > 0, do: Map.update(new_scores, owner_id, 200, &(&1 + 200)), else: new_scores

    RoomTracker.update_game_data(room_code, fn g -> %{g | scores: new_scores} end)
  end
end
