defmodule EvaWeb.Sessions.LedgerTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.Messages
  alias Eva.Agent.Session.Entries
  alias Eva.Agent.Session.Storage
  alias EvaWeb.Sessions.Ledger

  setup context do
    path = Path.join(System.tmp_dir!(), "eva_web_ledger_#{:erlang.phash2(context.test)}.jsonl")
    on_exit(fn -> File.rm(path) end)

    {:ok, storage: Storage.Jsonl.new(path), path: path}
  end

  defp user(storage, parent_id, text) do
    append(storage, Entries.Message.new(%{parent_id: parent_id, message: user_message(text)}))
  end

  defp assistant(storage, parent_id, text) do
    message = %Messages.AssistantMessage{content: [%Messages.TextContent{text: text}]}
    append(storage, Entries.Message.new(%{parent_id: parent_id, message: message}))
  end

  defp fork_entry(storage, parent_id, from_entry_id, session_id) do
    append(
      storage,
      Entries.Custom.new(%{
        parent_id: parent_id,
        namespace: "fork",
        data: %{
          title: "fork: original",
          forked_session_id: session_id,
          forked_from_entry_id: from_entry_id
        }
      })
    )
  end

  defp user_message(text), do: %Messages.UserMessage{content: text}

  defp append(storage, entry) do
    :ok = Storage.append(storage, entry)
    entry.id
  end

  # `leaf` is what marks the branch being read; without one every entry replays.
  defp leaf(storage, entry_id) do
    append(storage, Entries.Leaf.new(%{parent_id: entry_id, entry_id: entry_id}))
  end

  defp index(sessions) do
    Map.new(sessions, fn {id, title} -> {id, %{id: id, title: title}} end)
  end

  describe "read/2" do
    test "reports nothing for a session that has never been written to", %{path: path} do
      assert Ledger.read(path, %{}) == Ledger.empty()
    end

    test "gives back the entry to fork at behind each user message, in order", %{
      storage: storage,
      path: path
    } do
      first = user(storage, nil, "one")
      reply = assistant(storage, first, "hi")
      second = user(storage, reply, "two")
      leaf(storage, second)

      assert Ledger.fork_points(Ledger.read(path, %{})) == [first, second]
    end

    test "stamps every row with the time its entry was written", %{storage: storage, path: path} do
      first = user(storage, nil, "one")
      reply = assistant(storage, first, "hi")
      leaf(storage, reply)

      ledger = Ledger.read(path, %{})

      assert %{user?: true, at: asked_at} = Ledger.row(ledger, 0)
      assert %{user?: false, at: replied_at} = Ledger.row(ledger, 1)
      assert is_float(asked_at) and asked_at > 1_700_000_000
      assert replied_at >= asked_at
    end

    # The messages a view holds can run ahead of the transcript while a turn is in flight.
    test "has nothing to say about a row past the end of the transcript", %{
      storage: storage,
      path: path
    } do
      first = user(storage, nil, "one")
      leaf(storage, first)

      assert Ledger.row(Ledger.read(path, %{}), 9) == nil
    end

    test "groups forks under the message they were taken at", %{storage: storage, path: path} do
      first = user(storage, nil, "one")
      reply = assistant(storage, first, "hi")
      forked = fork_entry(storage, reply, first, "fork-1")
      second = user(storage, forked, "two")
      leaf(storage, second)

      forks = Ledger.read(path, index(%{"fork-1" => "a better idea"}))

      assert Ledger.forks_at(forks, first) == [%{session_id: "fork-1", title: "a better idea"}]
      assert Ledger.forks_at(forks, second) == []
    end

    # A fork is appended under the tip at the time, so it sits on a branch of its own until the
    # conversation moves past it. Reading only the active branch would miss exactly the fork the
    # user just took.
    test "sees a fork taken from the last message", %{storage: storage, path: path} do
      first = user(storage, nil, "one")
      leaf(storage, first)
      fork_entry(storage, first, first, "fork-1")

      forks = Ledger.read(path, index(%{"fork-1" => "a better idea"}))

      assert [%{session_id: "fork-1"}] = Ledger.forks_at(forks, first)
    end

    test "keeps every fork of the same message, in the order they were taken", %{
      storage: storage,
      path: path
    } do
      first = user(storage, nil, "one")
      forked = fork_entry(storage, first, first, "fork-1")
      fork_entry(storage, forked, first, "fork-2")
      leaf(storage, first)

      forks = Ledger.read(path, index(%{"fork-1" => "first try", "fork-2" => "second try"}))

      assert [%{session_id: "fork-1"}, %{session_id: "fork-2"}] = Ledger.forks_at(forks, first)
    end

    test "drops a fork whose session has been deleted", %{storage: storage, path: path} do
      first = user(storage, nil, "one")
      fork_entry(storage, first, first, "fork-1")
      leaf(storage, first)

      assert Ledger.forks_at(Ledger.read(path, %{}), first) == []
    end

    test "falls back to the recorded title for a fork that has never been renamed", %{
      storage: storage,
      path: path
    } do
      first = user(storage, nil, "one")
      fork_entry(storage, first, first, "fork-1")
      leaf(storage, first)

      forks = Ledger.read(path, index(%{"fork-1" => nil}))

      assert [%{title: "fork: original"}] = Ledger.forks_at(forks, first)
    end

    test "reports no forks rather than raising on a transcript it cannot replay", %{path: path} do
      File.write!(path, "not json at all\n")

      assert Ledger.read(path, %{}) == Ledger.empty()
    end
  end

  describe "forks_at/2" do
    test "answers for a row that has no entry to fork at" do
      assert Ledger.forks_at(Ledger.empty(), nil) == []
    end
  end
end
