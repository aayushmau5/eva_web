defmodule EvaWeb.Sessions.Ledger do
  @moduledoc """
  What the transcript on disk knows that the messages don't: when each row was written, and what
  has been forked from it.

  Eva hands clients a list of messages, and a message carries neither the entry it was stored as
  nor an honest timestamp — `Eva.Core.Agent.Messages` structs default theirs at compile time, so every
  message in a session claims the moment Eva was built. The append-only log has both, so this reads
  it back and lines it up with the messages, row for row.

  Forks are the other half. Eva forks at a user message: everything *before* it is copied into a
  new session, and the source session gets a `custom` entry in the `fork` namespace naming both.
  Nothing indexes those, so finding them means a scan — of *every* entry, not just the branch being
  displayed. A fork entry is appended under whatever the tip was when it was taken, so until the
  conversation continues past it, it hangs off the side of the branch and a walk up from the leaf
  never sees it.
  """

  require Logger

  alias Eva.Core.Agent.Messages
  alias Eva.Agent.Session.Entries
  alias Eva.Agent.Session.State, as: SessionState
  alias Eva.Agent.Session.Storage
  alias Eva.Agent.Session.Tree
  alias EvaWeb.Sessions

  @type fork :: %{session_id: String.t(), title: String.t()}

  @typedoc """
  One message row, in the order Eva replays them.

  `fork_point` is the entry to fork at, and is only set on rows Eva will actually fork from — a
  user message it stored itself.
  """
  @type row :: %{at: float() | nil, user?: boolean(), fork_point: String.t() | nil}

  @type t :: %{rows: [row()], forks: %{String.t() => [fork()]}}

  @empty %{rows: [], forks: %{}}

  @doc "The ledger of a session nobody has read yet."
  @spec empty() :: t()
  def empty, do: @empty

  @doc """
  Reads the ledger straight off the transcript at `session_path`.

  Whole-file work, so it belongs on a session's own process and not on every render — the price of
  Eva keeping this in the log rather than the index. A transcript that can't be replayed reports
  nothing instead of taking the caller down: the conversation is still readable without it.
  """
  @spec read(String.t(), %{String.t() => struct()} | nil) :: t()
  def read(session_path, known_sessions \\ nil) do
    entries = Storage.read_all(Storage.Jsonl.new(session_path))
    known = known_sessions || Sessions.index_by_id()

    %{rows: rows(entries), forks: forks(entries, known)}
  rescue
    error ->
      Logger.warning("Ledger: could not read #{session_path}: #{Exception.message(error)}")
      @empty
  end

  @doc "The row behind the nth message, or nil once past the end of what has been stored."
  @spec row(t(), non_neg_integer()) :: row() | nil
  def row(%{rows: rows}, index), do: Enum.at(rows, index)

  @doc """
  The entry to fork at behind each user bubble, in the order they are rendered.

  `nil` where a bubble is not something Eva will fork from, so that the list still lines up with
  what is on screen.
  """
  @spec fork_points(t()) :: [String.t() | nil]
  def fork_points(%{rows: rows}), do: for(%{user?: true} = row <- rows, do: row.fork_point)

  @doc "The forks taken from one entry, in the order they were taken."
  @spec forks_at(t(), String.t() | nil) :: [fork()]
  def forks_at(_ledger, nil), do: []
  def forks_at(%{forks: forks}, entry_id), do: Map.get(forks, entry_id, [])

  # -- Private --

  # `context_entry_ids` is Eva's own row-by-row account of which entry produced which message, so
  # walking it alongside the messages lands on exactly the rows the transcript renders, in order.
  defp rows(entries) do
    by_id = Tree.entries_by_id(entries)
    state = replay(entries)

    state.messages
    |> Enum.zip(state.context_entry_ids)
    |> Enum.map(fn {message, entry_id} ->
      entry = Map.get(by_id, entry_id)

      %{
        at: timestamp(entry),
        user?: match?(%Messages.UserMessage{}, message),
        fork_point: fork_point(entry)
      }
    end)
  end

  defp replay(entries) do
    case SessionState.latest_leaf_entry(entries) do
      nil -> SessionState.from_entries(entries)
      leaf -> SessionState.from_entries(entries, leaf.entry_id)
    end
  end

  defp timestamp(%{timestamp: at}) when is_number(at), do: at
  defp timestamp(_entry), do: nil

  # Eva only forks from a stored user message. A branch summary replays into a user message too and
  # is indistinguishable by then, so rows are judged by the entry they came from rather than the
  # message they turned into — asking Eva to fork at one of those would crash the session.
  defp fork_point(%Entries.Message{id: id, message: %Messages.UserMessage{}}), do: id
  defp fork_point(_entry), do: nil

  defp forks(entries, known) do
    entries
    |> Enum.flat_map(fn
      %Entries.Custom{namespace: "fork", data: data} -> fork_from(data, known)
      _entry -> []
    end)
    |> Enum.group_by(fn {from, _fork} -> from end, fn {_from, fork} -> fork end)
  end

  defp fork_from(data, known) when is_map(data) do
    from = value(data, :forked_from_entry_id)
    session_id = value(data, :forked_session_id)

    # The index is the authority on the title — a fork can be renamed after the fact — and on
    # whether it is still there at all. A session the user has since deleted leaves its fork entry
    # behind, and a link to it would only go nowhere.
    case Map.get(known, session_id) do
      nil -> []
      session -> [{from, %{session_id: session_id, title: title(session, data)}}]
    end
  end

  defp fork_from(_data, _known), do: []

  defp title(session, data) do
    session.title || value(data, :title) || "Untitled fork"
  end

  # Entry data is written with atom keys and read back off disk with string ones.
  defp value(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))
end
