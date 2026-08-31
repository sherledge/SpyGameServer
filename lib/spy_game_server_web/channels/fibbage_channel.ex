defmodule SpyGameServerWeb.FibbageChannel do
  use SpyGameServerWeb, :channel
  alias SpyGameServer.RoomTracker

  @num_rounds 2
  @truth_vote_points 500
  @per_lie_vote_points 250
  @answer_duration 30
  @vote_duration 20
  @reveal_gap_ms 2_500

  @impl true
  def join("fibbage:" <> room_code, _payload, socket) do
    case RoomTracker.get_room(room_code) do
      nil ->
        {:error, %{reason: "Room does not exist!"}}

      _room ->
        user_id = socket.assigns.user_id
        Phoenix.PubSub.subscribe(SpyGameServer.PubSub, "fibbage:#{room_code}:#{user_id}")
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
        questions = load_questions() |> Enum.shuffle() |> Enum.take(@num_rounds)

        game_data = %{
          questions: questions,
          currentRoundIndex: 0,
          currentQuestion: nil,
          currentAnswer: nil,
          answers: %{},
          votes: %{},
          scores: Enum.into(room.members, %{}, fn id -> {id, 0} end)
        }

        RoomTracker.set_game_data(room_code, game_data)

        Task.start(fn -> run_game_flow(room_code) end)
        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("submit_answer", %{"text" => text}, socket) do
    RoomTracker.update_game_data(socket.assigns.room_code, fn gd ->
      if gd != nil do
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
      # Can't vote for your own submitted lie. TRUTH and other players' lies are fair game.
      if gd != nil and socket.assigns.user_id != target_id do
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

  defp load_questions do
    path = Application.app_dir(:spy_game_server, "priv/fibbage_prompts.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) and length(list) > 0 ->
            Enum.map(list, fn %{"question" => q, "answer" => a} -> %{question: q, answer: a} end)

          _ ->
            [%{question: "What is the least favorite chore of a house cat?", answer: "Using the litter box"}]
        end

      _ ->
        [%{question: "What is the least favorite chore of a house cat?", answer: "Using the litter box"}]
    end
  end

  # --- Game flow ---

  defp run_game_flow(room_code) do
    room = RoomTracker.get_room(room_code)
    run_round(room_code, room.gameData.questions, 0)
  end

  defp run_round(room_code, questions, index) when index < length(questions) do
    q = Enum.at(questions, index)

    RoomTracker.update_game_data(room_code, fn gd ->
      %{gd | currentRoundIndex: index, currentQuestion: q.question, currentAnswer: q.answer, answers: %{}, votes: %{}}
    end)

    SpyGameServerWeb.Endpoint.broadcast("fibbage:#{room_code}", "question_phase_start", %{
      question: q.question,
      duration: @answer_duration,
      round: index + 1,
      totalRounds: length(questions)
    })

    # Buffer beyond the client countdown so late answers still land.
    Process.sleep((@answer_duration + 1) * 1000)

    room = RoomTracker.get_room(room_code)
    gd = room.gameData

    choices =
      (Enum.map(gd.answers, fn {writer_id, text} -> %{ownerId: writer_id, text: text} end) ++
         [%{ownerId: "TRUTH", text: gd.currentAnswer}])
      |> Enum.shuffle()

    SpyGameServerWeb.Endpoint.broadcast("fibbage:#{room_code}", "voting_phase_start", %{
      choices: choices,
      duration: @vote_duration
    })

    Process.sleep((@vote_duration + 1) * 1000)

    room2 = RoomTracker.get_room(room_code)
    reveal_and_score(room_code, room2, room2.gameData, choices)

    run_round(room_code, questions, index + 1)
  end

  defp run_round(room_code, _questions, _index) do
    room = RoomTracker.get_room(room_code)
    gd = room.gameData

    final_scores =
      gd.scores
      |> Enum.map(fn {id, score} -> %{name: Map.get(room.playerNames, id, "Player"), score: score} end)
      |> Enum.sort_by(& &1.score, :desc)

    SpyGameServerWeb.Endpoint.broadcast("fibbage:#{room_code}", "game_over", %{scores: final_scores})

    RoomTracker.delete_room(room_code)
    SpyGameServerWeb.Endpoint.broadcast("lobby:#{room.gameId}", "update_room_list", %{
      rooms: RoomTracker.get_all(room.gameId)
    })
  end

  defp reveal_and_score(room_code, room, gd, choices) do
    vote_counts =
      Enum.reduce(gd.votes, %{}, fn {_voter, target}, acc -> Map.update(acc, target, 1, &(&1 + 1)) end)

    voter_names_by_target =
      Enum.reduce(gd.votes, %{}, fn {voter_id, target}, acc ->
        name = Map.get(room.playerNames, voter_id, "Player")
        Map.update(acc, target, [name], &(&1 ++ [name]))
      end)

    # Skip zero-vote answers entirely, reveal least -> most voted, TRUTH lands last since
    # it's usually (though not always) the most-picked answer.
    choices
    |> Enum.filter(fn c -> Map.get(vote_counts, c.ownerId, 0) > 0 end)
    |> Enum.sort_by(fn c -> Map.get(vote_counts, c.ownerId, 0) end)
    |> Enum.each(fn c ->
      is_correct = c.ownerId == "TRUTH"

      SpyGameServerWeb.Endpoint.broadcast("fibbage:#{room_code}", "reveal_vote_result", %{
        text: c.text,
        isCorrect: is_correct,
        ownerName: if(is_correct, do: "Correct Answer", else: Map.get(room.playerNames, c.ownerId, "Player")),
        voteCount: Map.get(vote_counts, c.ownerId, 0),
        voterNames: Map.get(voter_names_by_target, c.ownerId, [])
      })

      Process.sleep(@reveal_gap_ms)
    end)

    new_scores =
      Enum.reduce(gd.votes, gd.scores, fn {voter_id, target}, scores ->
        if target == "TRUTH" do
          Map.update(scores, voter_id, @truth_vote_points, &(&1 + @truth_vote_points))
        else
          Map.update(scores, target, @per_lie_vote_points, &(&1 + @per_lie_vote_points))
        end
      end)

    RoomTracker.update_game_data(room_code, fn g -> %{g | scores: new_scores} end)
  end
end
