defmodule EvaWeb.Sessions.Runner do
  @moduledoc """
  Owns one `Eva.Coding.Session` and republishes its events on PubSub.

  Eva delivers agent events by plain `send/2` to a single `listener_pid` fixed when the session
  starts, which doesn't survive a LiveView reconnect. The Runner is that listener: it is supervised,
  long-lived, and rebroadcasts everything to `EvaWeb.Sessions.topic/1` so any number of LiveViews
  can attach and detach freely. It also answers `:snapshot`, which is how a view that attaches
  mid-conversation catches up.
  """

  # :temporary because the usual reason a Runner dies is an unreadable transcript or an Eva-side
  # crash — restarting would just fail the same way in a loop. The LiveView monitors it and lets
  # the user retry by reopening the session.
  use GenServer, restart: :temporary

  require Logger

  alias Eva.Agent.Events
  alias Eva.Agent.Messages
  alias Eva.Agent.Session.Storage
  alias Eva.AI.Config, as: ProviderConfig
  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.Session.SessionConfig
  alias Eva.Coding.SessionIndexManager
  alias EvaWeb.Sessions

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

  @spec snapshot(GenServer.server()) :: %{messages: [struct()], running?: boolean()}
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @spec prompt(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def prompt(server, text), do: GenServer.call(server, {:prompt, text})

  @spec cancel(GenServer.server()) :: :ok
  def cancel(server), do: GenServer.call(server, :cancel)

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
    config = Sessions.eva_config()

    provider_config = %ProviderConfig.OpenAICompatible{
      base_url: config[:base_url],
      provider_name: config[:provider_name]
    }

    session_config = %SessionConfig{
      cwd: entry.cwd,
      storage: Storage.Jsonl.new(entry.session_path),
      session_index_manager: SessionIndexManager.new(),
      session_id: entry.id,
      model: config[:model],
      provider_config: provider_config,
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
      running?: false,
      titled?: not is_nil(entry.title)
    }
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{messages: CodingSession.messages(state.session_pid), running?: state.running?},
     state}
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

  def handle_info(%Events.MessageEnd{message: %Messages.UserMessage{} = message} = event, state) do
    broadcast(state, event)
    {:noreply, maybe_title_from(state, message)}
  end

  def handle_info(%{__struct__: module} = event, state) when is_atom(module) do
    if agent_event?(module) do
      broadcast(state, event)
    end

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

  # Mirrored into this process's registry value so the sidebar can read every session's state in a
  # single ETS lookup instead of calling each runner.
  defp set_running(state, running?) do
    Registry.update_value(EvaWeb.SessionRegistry, state.session_id, fn _ -> running? end)
    %{state | running?: running?}
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(EvaWeb.PubSub, Sessions.topic(state.session_id), {:eva, event})
  end

  defp agent_event?(module) do
    match?("Elixir.Eva.Agent.Events." <> _, Atom.to_string(module))
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
