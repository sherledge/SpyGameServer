defmodule SpyGameServerWeb.WordleChannel do
  use SpyGameServerWeb, :channel
  alias SpyGameServer.RoomTracker

  @max_guesses 6

  @impl true
  def join("wordle:" <> room_code, _payload, socket) do
    case RoomTracker.get_room(room_code) do
      nil ->
        {:error, %{reason: "Room does not exist!"}}

      _room ->
        user_id = socket.assigns.user_id
        Phoenix.PubSub.subscribe(SpyGameServer.PubSub, "wordle:#{room_code}:#{user_id}")
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

      length(room.members) != 2 ->
        {:reply, {:error, %{reason: "Wordle needs exactly 2 players!"}}, socket}

      true ->
        secret_word = Enum.random(load_answer_words())
        [first_player, second_player] = room.members

        game_data = %{
          secretWord: secret_word,
          guesses: [],
          currentTurnPlayerId: first_player,
          otherPlayerId: second_player,
          maxGuesses: @max_guesses
        }

        RoomTracker.set_game_data(room_code, game_data)

        SpyGameServerWeb.Endpoint.broadcast("wordle:#{room_code}", "game_started_init", %{
          maxGuesses: @max_guesses,
          firstTurnPlayerId: first_player
        })

        {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("submit_guess", %{"word" => raw_word}, socket) do
    room_code = socket.assigns.room_code
    user_id = socket.assigns.user_id
    room = RoomTracker.get_room(room_code)
    gd = room && room.gameData
    word = raw_word |> String.upcase() |> String.trim()

    cond do
      gd == nil ->
        {:reply, {:error, %{reason: "No active game"}}, socket}

      user_id != gd.currentTurnPlayerId ->
        {:reply, {:error, %{reason: "Not your turn!"}}, socket}

      String.length(word) != 5 ->
        {:reply, {:error, %{reason: "Word must be 5 letters"}}, socket}

      not MapSet.member?(load_valid_words(), word) ->
        {:reply, {:error, %{reason: "Not a valid word"}}, socket}

      true ->
        results = score_guess(word, gd.secretWord)
        won = word == gd.secretWord

        guess_entry = %{playerId: user_id, word: word, results: results}
        new_guesses = gd.guesses ++ [guess_entry]
        guesses_used = length(new_guesses)
        game_over? = won or guesses_used >= gd.maxGuesses

        next_turn = if user_id == gd.currentTurnPlayerId, do: gd.otherPlayerId, else: gd.currentTurnPlayerId

        updated_gd = %{gd | guesses: new_guesses, currentTurnPlayerId: next_turn}
        RoomTracker.set_game_data(room_code, updated_gd)

        SpyGameServerWeb.Endpoint.broadcast("wordle:#{room_code}", "guess_result", %{
          playerId: user_id,
          playerName: Map.get(room.playerNames, user_id, "Player"),
          word: word,
          results: results,
          guessNumber: guesses_used,
          maxGuesses: gd.maxGuesses,
          nextTurnPlayerId: next_turn,
          gameOver: game_over?,
          won: won
        })

        if game_over? do
          winner_id = if won, do: user_id, else: nil

          SpyGameServerWeb.Endpoint.broadcast("wordle:#{room_code}", "game_over", %{
            won: won,
            secretWord: gd.secretWord,
            winnerId: winner_id
          })

          RoomTracker.delete_room(room_code)
          SpyGameServerWeb.Endpoint.broadcast("lobby:#{room.gameId}", "update_room_list", %{
            rooms: RoomTracker.get_all(room.gameId)
          })
        end

        {:reply, :ok, socket}
    end
  end

  # --- Wordle scoring: classic two-pass algorithm, handles duplicate letters correctly ---

  defp score_guess(guess, secret) do
    guess_letters = String.graphemes(guess)
    secret_letters = String.graphemes(secret)
    len = length(secret_letters)

    initial_results = List.duplicate("grey", len)

    {results_after_green, remaining} =
      Enum.reduce(0..(len - 1), {initial_results, Enum.frequencies(secret_letters)}, fn i, {res, freq} ->
        g = Enum.at(guess_letters, i)
        s = Enum.at(secret_letters, i)

        if g == s do
          {List.replace_at(res, i, "green"), Map.update!(freq, s, &(&1 - 1))}
        else
          {res, freq}
        end
      end)

    {final_results, _} =
      Enum.reduce(0..(len - 1), {results_after_green, remaining}, fn i, {res, freq} ->
        if Enum.at(res, i) == "green" do
          {res, freq}
        else
          g = Enum.at(guess_letters, i)
          count = Map.get(freq, g, 0)

          if count > 0 do
            {List.replace_at(res, i, "yellow"), Map.update!(freq, g, &(&1 - 1))}
          else
            {res, freq}
          end
        end
      end)

    final_results
  end

  # --- Word lists ---

  defp load_answer_words do
    load_word_list("priv/wordle_answers.json", ["CRANE", "SLATE", "TRACE", "ADIEU", "ROAST"])
  end

  defp load_valid_words do
    (load_word_list("priv/wordle_valid.json", []) ++ load_answer_words())
    |> MapSet.new()
  end

  defp load_word_list(rel_path, fallback) do
    path = Application.app_dir(:spy_game_server, rel_path)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) and length(list) > 0 ->
            Enum.map(list, &String.upcase/1)

          _ ->
            fallback
        end

      _ ->
        fallback
    end
  end

  # --- Shared helpers ---

  defp player_list(room) do
    Enum.map(room.members, fn id -> %{id: id, name: Map.get(room.playerNames, id, "Player")} end)
  end
end
