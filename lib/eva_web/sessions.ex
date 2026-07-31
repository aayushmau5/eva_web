defmodule EvaWeb.Sessions do
  @moduledoc """
  Web-facing entry point to Eva coding sessions.

  Eva persists every session as a JSONL transcript under `~/.eva/sessions/<project>/`, with an
  `index.jsonl` per project listing its sessions. This module reads those indexes for the session
  list, and starts a supervised `EvaWeb.Sessions.Runner` per session the user actually opens.

  Runners are supervised by `EvaWeb.SessionSupervisor` and registered by session id in
  `EvaWeb.SessionRegistry`, so a session outlives the LiveView that opened it (reconnects,
  navigation) and a crash on either side doesn't take the other down.
  """

  alias Eva.Agent.Session.Entries.SessionIndexEntry
  alias Eva.Coding.Paths, as: EvaPaths
  alias Eva.Coding.SessionIndexManager
  alias EvaWeb.Providers
  alias EvaWeb.Sessions.Runner

  @index_topic "eva:sessions"

  @type group :: %{
          cwd: String.t(),
          label: String.t(),
          updated_at: float(),
          sessions: [SessionIndexEntry.t()]
        }

  # -- Index --

  @doc "A fresh `SessionIndexManager` pointed at `~/.eva`."
  @spec manager() :: SessionIndexManager.t()
  def manager, do: SessionIndexManager.new(%EvaPaths{})

  @doc """
  Every known session across every project, grouped by working directory.

  Groups are ordered by their most recently touched session, and sessions within a group keep the
  `updated_at desc` order `list_sessions/2` already applies.
  """
  @spec list_grouped() :: [group()]
  def list_grouped do
    manager()
    |> SessionIndexManager.list_sessions(nil)
    |> Enum.group_by(& &1.cwd)
    |> Enum.map(fn {cwd, sessions} ->
      %{
        cwd: cwd,
        label: Path.basename(cwd),
        updated_at: sessions |> Enum.map(& &1.updated_at) |> Enum.max(fn -> 0.0 end),
        sessions: Enum.sort_by(sessions, & &1.updated_at, :desc)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  @doc "The index entry for `session_id`, or nil."
  @spec get(String.t()) :: SessionIndexEntry.t() | nil
  def get(session_id), do: SessionIndexManager.get_session(manager(), session_id)

  @doc """
  Every known session keyed by id.

  `get/1` reads every project index to answer for one session, so anything resolving a handful of
  ids at once — the forks hanging off a transcript, say — should read the lot once instead.
  """
  @spec index_by_id() :: %{String.t() => SessionIndexEntry.t()}
  def index_by_id do
    manager()
    |> SessionIndexManager.list_sessions(nil)
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Creates an empty session for `cwd` and returns its id.

  The index entry is written up front so the session shows in the sidebar before its first
  message. `title` is left nil so Eva's auto-naming still claims it on the first prompt.

  `:provider` and `:model` are recorded on the entry and are what the session actually runs
  against — see `EvaWeb.Sessions.Runner`. Both fall back to the configured defaults, so
  `create(cwd)` still means "a session like every other one".
  """
  @spec create(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def create(cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    provider_name = presence(opts[:provider]) || Providers.default_name()
    model = presence(opts[:model]) || Providers.default_model()

    cond do
      not File.dir?(cwd) ->
        {:error, "#{cwd} is not a directory"}

      not Providers.known?(provider_name) ->
        {:error, "#{provider_name} is not a provider Eva knows"}

      is_nil(model) ->
        {:error, "pick a model first"}

      true ->
        entry =
          SessionIndexManager.create_index(manager(), %{
            cwd: cwd,
            model: model,
            provider_name: provider_name
          })

        broadcast_index_change()
        {:ok, entry.id}
    end
  end

  @doc """
  Deletes a session and its transcript. The conversation is gone for good.

  The runner is stopped first so nothing keeps appending to a file that is no longer indexed.
  """
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(session_id) do
    stop(session_id)

    case SessionIndexManager.delete_session(manager(), session_id) do
      :ok ->
        broadcast_index_change()
        :ok

      {:error, :not_found} ->
        {:error, "session not found"}

      {:error, reason} ->
        broadcast_index_change()
        {:error, "could not remove transcript: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Renames a session. If the runner is running the change happens through it so the transcript
  stays consistent; otherwise the index entry is updated directly.
  """
  @spec rename(String.t(), String.t()) :: :ok | {:error, String.t()}
  def rename(session_id, name) do
    name = String.trim(name)

    if name == "" do
      {:error, "name must not be blank"}
    else
      case whereis(session_id) do
        pid when is_pid(pid) ->
          Runner.rename(pid, name)
          broadcast_index_change()

        nil ->
          SessionIndexManager.touch_session(manager(), session_id, nil, nil, name)
          broadcast_index_change()
      end

      :ok
    end
  end

  # -- Runners --

  @doc "Stops a session's runner if it is running. The transcript on disk is untouched."
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(EvaWeb.SessionSupervisor, pid)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Starts the runner for `session_id` if it isn't already running."
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               EvaWeb.SessionSupervisor,
               {Runner, session_id: session_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Current transcript and run state for an open session.

  Returns `{:error, reason}` rather than raising if the runner died between being started and
  being asked — an unreadable transcript shouldn't take a LiveView down with it.
  """
  @spec snapshot(String.t()) ::
          {:ok,
           %{
             messages: [struct()],
             running?: boolean(),
             mcp: EvaWeb.Sessions.MCP.t(),
             ledger: EvaWeb.Sessions.Ledger.t()
           }}
          | {:error, term()}
  def snapshot(session_id) do
    {:ok, Runner.snapshot(via(session_id))}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Forks a session at one of its user messages.

  Everything before that message is copied into a new session, and the message itself comes back as
  `:prefill` rather than being sent: forking is for taking the same conversation somewhere else, so
  the prompt lands in the composer for the user to edit.

  `entry_id` has to be one Eva will fork from — see `EvaWeb.Sessions.Ledger`.
  """
  @spec fork(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), title: String.t(), prefill: String.t()}}
          | {:error, term()}
  def fork(session_id, entry_id) do
    case Runner.fork(via(session_id), entry_id) do
      {:ok, fork} ->
        broadcast_index_change()
        {:ok, fork}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Sends a prompt. When the harness is mid-run the message is queued as a follow-up rather than
  rejected, so typing while Eva is working does something sensible.
  """
  @spec prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def prompt(session_id, text) do
    Runner.prompt(via(session_id), text)
  catch
    # A session that has died, or is wedged behind something slow, must not take the caller's
    # LiveView down with it — every other call into a Runner is guarded the same way.
    :exit, reason -> {:error, reason}
  end

  @doc "Interrupts the running agent loop."
  @spec cancel(String.t()) :: :ok
  def cancel(session_id), do: Runner.cancel(via(session_id))

  @doc """
  Runs a shell command in the session's working directory and records it in the transcript.

  This is the `!` escape hatch: the command is the user's, not the model's, but it is kept in the
  conversation either way. With `exclude_from_context: true` it stays out of what the model is
  sent, which is the difference between showing Eva what you just ran and only looking at it
  yourself.

  Eva refuses while the agent is mid-turn — injecting into the message list under a running loop
  would be overwritten by it — which comes back as `{:error, :agent_running}`.
  """
  @spec run_bash(String.t(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def run_bash(session_id, command, opts \\ []) do
    Runner.run_bash(via(session_id), command, opts)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Stops the command a session is running.

  The command is still recorded — Eva reports a killed command with `cancelled: true` and whatever
  it managed to print, so the transcript says what happened rather than losing it.
  """
  @spec cancel_bash(String.t()) :: :ok | {:error, term()}
  def cancel_bash(session_id) do
    Runner.cancel_bash(via(session_id))
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Switches an MCP server on or off for a session, or for every session to come.

  See `EvaWeb.Sessions.Runner.set_mcp_enabled/4` for what the two scopes mean. Returns
  `{:error, reason}` rather than raising if the runner has gone away in between.
  """
  @spec set_mcp_enabled(String.t(), String.t(), boolean(), :session | :persist) ::
          :ok | {:error, term()}
  def set_mcp_enabled(session_id, name, enabled?, scope) do
    Runner.set_mcp_enabled(via(session_id), name, enabled?, scope)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Ids of sessions whose agent is currently working, for the sidebar's activity dot.

  Each Runner keeps this flag in its own registry value, so reading it is one ETS lookup rather
  than a call per open session. Having a Runner at all isn't interesting here — a loaded but idle
  session should look no different from one that isn't loaded.
  """
  @spec running_ids() :: MapSet.t(String.t())
  def running_ids do
    EvaWeb.SessionRegistry
    |> Registry.select([{{:"$1", :_, true}, [], [:"$1"]}])
    |> MapSet.new()
  end

  # -- PubSub --

  @doc "Subscribes the caller to `{:eva, event}` messages for one session."
  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(EvaWeb.PubSub, topic(session_id))

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id), do: Phoenix.PubSub.unsubscribe(EvaWeb.PubSub, topic(session_id))

  @doc "Subscribes the caller to `:sessions_changed` for the session list."
  @spec subscribe_index() :: :ok
  def subscribe_index, do: Phoenix.PubSub.subscribe(EvaWeb.PubSub, @index_topic)

  @spec broadcast_index_change() :: :ok
  def broadcast_index_change,
    do: Phoenix.PubSub.broadcast(EvaWeb.PubSub, @index_topic, :sessions_changed)

  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "eva:session:#{session_id}"

  # -- Config --

  @doc "Model and provider defaults new sessions are created with."
  @spec eva_config() :: keyword()
  def eva_config, do: Application.get_env(:eva_web, :eva, [])

  # -- Private --

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp via(session_id), do: Runner.via(session_id)

  defp whereis(session_id) do
    case Registry.lookup(EvaWeb.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
