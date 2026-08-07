defmodule EvaWeb.Sessions.Runner do
  @moduledoc """
  Owns one `Eva.Coding.Session` and republishes its events on PubSub.

  Eva delivers agent events by plain `send/2` to a single `listener_pid` fixed when the session
  starts, which doesn't survive a LiveView reconnect. The Runner is that listener: it is supervised,
  long-lived, and rebroadcasts everything to `EvaWeb.Sessions.topic/1` so any number of LiveViews
  can attach and detach freely. It also answers `:snapshot`, which is how a view that attaches
  mid-conversation catches up.

  Extensions are held here rather than in each view, for the same reason: a LiveView that connects
  late would otherwise have no way to learn what the session loaded. They announce nothing, so
  there is no stream to fold — the set changes only when someone toggles, reloads or approves one,
  and it is re-read and published whole at each of those points.
  """

  # :temporary because the usual reason a Runner dies is an unreadable transcript or an Eva-side
  # crash — restarting would just fail the same way in a loop. The LiveView monitors it and lets
  # the user retry by reopening the session.
  use GenServer, restart: :temporary

  require Logger

  alias Eva.Core.Agent.Events
  alias Eva.Core.Agent.Messages
  alias Eva.Agent.Session.Storage
  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.Session.SessionConfig
  alias Eva.Coding.SessionIndexManager
  alias EvaWeb.Providers
  alias EvaWeb.Sessions
  alias EvaWeb.Sessions.Extensions
  alias EvaWeb.Sessions.Ledger

  # Eva's naming Task can finish after the agent run does; re-check once so the sidebar picks the
  # generated title up without a manual refresh.
  @title_recheck_ms 5_000
  @title_length 48

  # -- Public API --

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc "Registry key for a session, whose value carries whether the agent is currently working."
  def via(session_id), do: {:via, Registry, {EvaWeb.SessionRegistry, session_id, false}}

  @spec snapshot(GenServer.server()) :: %{
          messages: [struct()],
          running?: boolean(),
          extensions: Extensions.t(),
          ledger: Ledger.t(),
          command: String.t() | nil
        }
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  Forks the session at `entry_id`, a user message in its transcript.

  See `EvaWeb.Sessions.fork/2`. Everyone watching the source session is told about the new fork, so
  the message it was taken from grows a link to it without a reload.
  """
  @spec fork(GenServer.server(), String.t()) ::
          {:ok, %{session_id: String.t(), title: String.t(), prefill: String.t()}}
          | {:error, term()}
  def fork(server, entry_id), do: GenServer.call(server, {:fork, entry_id})

  @spec prompt(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def prompt(server, text), do: GenServer.call(server, {:prompt, text})

  @doc """
  Runs a shell command in the session's working directory.

  Eva runs it synchronously and answers only when the command is done, so this call waits with it —
  the caller's own timeout would otherwise fire while the command is still running, and the reply
  would land in a mailbox nobody is reading. What bounds it is Eva's `:timeout`, not this.
  """
  @spec run_bash(GenServer.server(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def run_bash(server, command, opts \\ []) do
    GenServer.call(server, {:run_bash, command, opts}, :infinity)
  end

  @doc """
  Kills the command a session is running.

  The command still finishes the ordinary way — Eva reports it with `cancelled: true` rather than
  dropping it — so the caller of `run_bash/3` gets its reply and the transcript keeps the record.
  """
  @spec cancel_bash(GenServer.server()) :: :ok | {:error, term()}
  def cancel_bash(server), do: GenServer.call(server, :cancel_bash)

  @spec cancel(GenServer.server()) :: :ok
  def cancel(server), do: GenServer.call(server, :cancel)

  @doc """
  Renames a running session. The title is persisted to the index entry so it outlives the runner.
  """
  @spec rename(GenServer.server(), String.t()) :: :ok
  def rename(server, name) do
    GenServer.call(server, {:rename_session, name})
  end

  @doc """
  Switches an extension on or off for this session, recorded in its transcript so it survives a
  resume.

  Switching one off stops its process; switching one on compiles the file and runs its `setup/1`,
  because a disabled extension was never loaded in the first place. Eva refuses both while the
  agent is running — the loop is holding the hook functions the extension's process backs, and an
  unreachable hook reads as a block.
  """
  @spec set_extension_enabled(GenServer.server(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_extension_enabled(server, name, enabled?) do
    GenServer.call(server, {:set_extension_enabled, name, enabled?}, 30_000)
  end

  @doc """
  Re-reads every extension directory and recompiles what it finds.

  This is the only way to pick up an edit: modules are compiled into the VM once and cached for
  its lifetime, so a changed `.exs` is invisible until the old one is purged. Also refused while
  the agent is running.
  """
  @spec reload_extensions(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def reload_extensions(server) do
    GenServer.call(server, :reload_extensions, 30_000)
  end

  @doc """
  Approves the extension directories this session skipped, and loads them.

  A project's `.eva/extensions` is whatever the repository ships, and it runs before the first
  prompt — so Eva holds it back until someone says yes. Consent covers the directory as it stands
  now: editing an extension asks again. Answers with the directories approved, `[]` when there was
  nothing waiting, and refuses mid-turn, since approving is a reload.
  """
  @spec trust_extensions(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def trust_extensions(server) do
    GenServer.call(server, :trust_extensions, 30_000)
  end

  # -- GenServer --

  # Starting the Eva session happens here rather than in handle_continue so that a session which
  # can't be replayed (a corrupt or old-format transcript) surfaces as a start_child error the
  # caller can report, instead of a process that dies just after being handed back.
  @impl true
  def init(session_id) do
    case Sessions.get(session_id) do
      nil -> {:stop, {:unknown_session, session_id}}
      entry -> {:ok, start_session(session_id, entry)}
    end
  end

  defp start_session(session_id, entry) do
    session_config = %SessionConfig{
      cwd: entry.cwd,
      storage: Storage.Jsonl.new(entry.session_path),
      session_index_manager: SessionIndexManager.new(),
      session_id: entry.id,
      model: entry.model || Providers.default_model(),
      provider_config: provider_config(entry),
      listener_pid: self()
    }

    {:ok, session_pid} = CodingSession.start_link(%{config: session_config})

    # start_link returns before Eva replays the transcript in handle_continue, so block on a call
    # that queues behind it. A transcript Eva can't parse then fails our init rather than killing
    # this process moments after the caller was handed a pid.
    _cwd = CodingSession.cwd(session_pid)

    %{
      session_id: session_id,
      session_pid: session_pid,
      cwd: entry.cwd,
      # Timestamps and forks live in the transcript rather than the index, so they are read back
      # off the file itself — see `EvaWeb.Sessions.Ledger`.
      session_path: entry.session_path,
      running?: false,
      # The `!` command in flight, if any. Held here rather than in the views so that one opened
      # mid-command still shows the row and the button that stops it.
      command: nil,
      titled?: not is_nil(entry.title),
      # Extensions are loaded synchronously during Eva's own startup, which the `cwd/1` call above
      # has already waited out — so this reads a finished set rather than an empty one.
      extensions: read_extensions(entry.cwd, session_pid)
    }
  end

  # Extensions are re-read rather than answered from state. Toggling, reloading and approving all
  # republish, so state is usually right — but an extension running on its own node joins and
  # leaves whenever someone starts or stops it, and nothing tells this process when that happens.
  # The moment a view asks is the freshest answer available.
  @impl true
  def handle_call(:snapshot, _from, state) do
    state = %{state | extensions: read_extensions(state.cwd, state.session_pid)}

    reply = %{
      messages: CodingSession.messages(state.session_pid),
      running?: state.running?,
      extensions: state.extensions,
      ledger: Ledger.read(state.session_path),
      command: state.command
    }

    {:reply, reply, state}
  end

  def handle_call({:fork, entry_id}, _from, state) do
    case CodingSession.fork(state.session_pid, entry_id) do
      {:ok, session_id, title, prefill} ->
        publish_ledger(state)
        {:reply, {:ok, %{session_id: session_id, title: title, prefill: prefill}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Eva broadcasts the finished command as a `MessageEnd`, which reaches every view watching the
  # session — so the row is not published from here, only the outcome the caller is waiting on.
  def handle_call({:run_bash, command, opts}, from, state) do
    # Answered from the task rather than here: Eva replies to `run_bash` only when the command is
    # done, and blocking this process meanwhile would stall every other call to the session —
    # prompts, snapshots, the cancel that is meant to stop the command in the first place.
    session_pid = state.session_pid

    Task.Supervisor.start_child(EvaWeb.TaskSupervisor, fn ->
      GenServer.reply(from, CodingSession.run_bash(session_pid, command, opts))
    end)

    {:noreply, state}
  end

  def handle_call(:cancel_bash, _from, state) do
    {:reply, CodingSession.cancel_bash(state.session_pid), state}
  end

  def handle_call({:prompt, text}, _from, state) do
    # `running?` is inferred from events, so it can lag a beat. Trust it first, but fall back to
    # queueing as a follow-up if Eva disagrees, rather than dropping the message.
    behaviour = if state.running?, do: :follow_up, else: nil

    reply =
      case CodingSession.prompt(state.session_pid, text, behaviour) do
        {:error, _reason} when is_nil(behaviour) ->
          CodingSession.prompt(state.session_pid, text, :follow_up)

        other ->
          other
      end

    {:reply, reply, state}
  end

  def handle_call(:cancel, _from, state) do
    :ok = CodingSession.cancel(state.session_pid)
    {:reply, :ok, set_running(state, false)}
  end

  def handle_call({:rename_session, name}, _from, state) do
    _name = CodingSession.rename_session(state.session_pid, name)
    Sessions.broadcast_index_change()
    {:reply, :ok, state}
  end

  # Eva answers a toggle with the new list, but not with the commands or the diagnostics that go
  # with it — and enabling one that won't compile is answered with an error while the rest of the
  # set stays exactly as it was. Re-reading all three is what keeps the panel honest either way.
  def handle_call({:set_extension_enabled, name, enabled?}, _from, state) do
    case CodingSession.set_extension_enabled(state.session_pid, name, enabled?) do
      {:ok, _infos} -> {:reply, :ok, publish_extensions(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Answered with what the panel will show rather than with Eva's own list: a directory waiting for
  # approval is a diagnostic there too, and reporting it as a problem with the reload would be
  # counting a question as a failure.
  def handle_call(:reload_extensions, _from, state) do
    case CodingSession.reload_extensions(state.session_pid) do
      {:ok, _diagnostics} ->
        state = publish_extensions(state)
        {:reply, {:ok, state.extensions.diagnostics}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Approving reloads the set, so the panel is republished either way — including the case where
  # nothing was waiting, which costs one read and keeps a stale row from surviving a race.
  def handle_call(:trust_extensions, _from, state) do
    case CodingSession.trust_extensions(state.session_pid) do
      {:ok, approved} -> {:reply, {:ok, approved}, publish_extensions(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # -- Agent events --

  @impl true
  def handle_info(%Events.AgentStart{} = event, state) do
    broadcast(state, event)
    Sessions.broadcast_index_change()
    {:noreply, set_running(state, true)}
  end

  def handle_info(%Events.AgentEnd{} = event, state) do
    broadcast(state, event)
    Sessions.broadcast_index_change()
    if not state.titled?, do: Process.send_after(self(), :recheck_title, @title_recheck_ms)
    {:noreply, set_running(state, false)}
  end

  # A user message is only forkable once it has an entry to fork at, which is a moment after it is
  # spoken. Eva writes the entry before it forwards this event, so re-reading here is safe, and it
  # is the one point at which the set of fork points can grow.
  def handle_info(%Events.MessageEnd{message: %Messages.UserMessage{} = message} = event, state) do
    broadcast(state, event)
    publish_ledger(state)
    {:noreply, maybe_title_from(state, message)}
  end

  def handle_info(
        %Events.MessageStart{message: %Messages.BashExecutionMessage{} = message} = event,
        state
      ) do
    broadcast(state, event)
    {:noreply, %{state | command: message.command}}
  end

  def handle_info(
        %Events.MessageEnd{message: %Messages.BashExecutionMessage{}} = event,
        state
      ) do
    broadcast(state, event)
    {:noreply, %{state | command: nil}}
  end

  # Eva's session publishes this whenever its set of extensions changes — including when an
  # extension node joins or leaves, which nothing else here would ever hear about. The event
  # carries nothing on purpose: re-reading is the answer, and it cannot be stale by the time it
  # arrives the way a payload could.
  def handle_info(%Events.ExtensionsChanged{}, state) do
    {:noreply, publish_extensions(state)}
  end

  # -- Everything else Eva sends --

  # Including `Events.ExtensionEvent`, which is how anything an extension publishes arrives — MCP's
  # server connected/failed among them, now that MCP is an extension rather than part of Eva. It
  # is an agent event like any other, even when it came from another node, so it is broadcast
  # rather than folded into state here.
  def handle_info(event, state) when is_struct(event) do
    if agent_event?(event.__struct__), do: broadcast(state, event)
    {:noreply, state}
  end

  # -- Housekeeping --

  def handle_info(:recheck_title, state) do
    titled? =
      case Sessions.get(state.session_id) do
        %{title: title} when is_binary(title) ->
          Sessions.broadcast_index_change()
          true

        _ ->
          false
      end

    {:noreply, %{state | titled?: titled?}}
  end

  def handle_info(message, state) do
    Logger.debug("EvaWeb.Sessions.Runner #{state.session_id} ignoring #{inspect(message)}")
    {:noreply, state}
  end

  # -- Private --

  # Sessions written before the provider was pickable, or against a provider that has since been
  # dropped from the catalog, still have to open — they just open on the configured default.
  defp provider_config(entry) do
    Providers.config(entry.provider_name) || Providers.config(Providers.default_name())
  end

  # Mirrored into this process's registry value so the sidebar can read every session's state in a
  # single ETS lookup instead of calling each runner.
  defp set_running(state, running?) do
    Registry.update_value(EvaWeb.SessionRegistry, state.session_id, fn _ -> running? end)
    %{state | running?: running?}
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(EvaWeb.PubSub, Sessions.topic(state.session_id), {:eva, event})
  end

  defp publish_extensions(state) do
    extensions = read_extensions(state.cwd, state.session_pid)

    Phoenix.PubSub.broadcast(
      EvaWeb.PubSub,
      Sessions.topic(state.session_id),
      {:extensions, extensions}
    )

    %{state | extensions: extensions}
  end

  defp read_extensions(cwd, session_pid) do
    Extensions.new(
      cwd,
      CodingSession.list_extensions(session_pid),
      CodingSession.extension_commands(session_pid),
      CodingSession.extension_diagnostics(session_pid)
    )
  end

  # Read fresh rather than held in state: fork titles come from the session index, which anything
  # renaming or deleting a fork changes behind this process's back.
  defp publish_ledger(state) do
    ledger = Ledger.read(state.session_path)
    Phoenix.PubSub.broadcast(EvaWeb.PubSub, Sessions.topic(state.session_id), {:ledger, ledger})
  end

  defp agent_event?(module) do
    match?("Elixir.Eva.Core.Agent.Events." <> _, Atom.to_string(module))
  end

  # Gives a brand new session a readable name straight away. Eva also names sessions with an LLM
  # call, which lands later and overwrites this with something better.
  defp maybe_title_from(%{titled?: true} = state, _message), do: state

  defp maybe_title_from(state, message) do
    case excerpt(Messages.UserMessage.text(message)) do
      nil ->
        state

      title ->
        SessionIndexManager.touch_session(Sessions.manager(), state.session_id, nil, nil, title)
        Sessions.broadcast_index_change()
        %{state | titled?: true}
    end
  end

  defp excerpt(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      line when byte_size(line) <= @title_length -> line
      line -> String.slice(line, 0, @title_length) <> "…"
    end
  end
end
