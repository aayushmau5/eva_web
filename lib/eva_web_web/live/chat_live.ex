defmodule EvaWebWeb.ChatLive do
  @moduledoc """
  The chat UI: session list, session switching, and a live transcript.

  Session state lives in `EvaWeb.Sessions.Runner`, not here. On mount (and on every reconnect or
  session switch) this view pulls a snapshot and re-streams it, then applies agent events as they
  arrive over PubSub. It never reloads history mid-conversation — doing that on `AgentStart` is what
  used to duplicate the whole transcript on every turn.
  """
  use EvaWebWeb, :live_view

  import EvaWebWeb.ChatComponents

  alias Eva.Agent.Events
  alias Eva.Agent.Messages
  alias EvaWeb.Providers
  alias EvaWeb.Sessions
  alias EvaWeb.Sessions.Transcript

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sessions.subscribe_index()

    {:ok,
     socket
     |> assign(
       page_title: "Eva",
       session: nil,
       session_id: nil,
       running?: false,
       current_id: nil,
       next_index: 0,
       tool_args: %{},
       monitor_ref: nil,
       pending_delete: nil,
       providers: Providers.all(),
       new_session: nil,
       new_project: nil,
       queued_messages: [],
       last_model: nil,
       last_provider: nil
     )
     |> assign_sessions()
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(%{"id" => session_id}, _uri, socket) do
    cond do
      session_id == socket.assigns.session_id ->
        {:noreply, socket}

      is_nil(Sessions.get(session_id)) ->
        {:noreply,
         socket
         |> put_flash(:error, "That session no longer exists.")
         |> push_patch(to: ~p"/")}

      true ->
        {:noreply, open_session(socket, session_id)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, close_session(socket)}
  end

  # -- User actions --

  @impl true
  def handle_event("start_new_project", _params, socket) do
    {:noreply,
     socket |> assign(:new_project, %{cwd: default_cwd(socket)}) |> assign(:new_session, nil)}
  end

  def handle_event("cancel_new_project", _params, socket) do
    {:noreply, assign(socket, :new_project, nil)}
  end

  def handle_event("new_project_change", %{"cwd" => cwd}, socket) do
    {:noreply, assign(socket, :new_project, %{cwd: cwd})}
  end

  def handle_event("new_project", %{"cwd" => cwd}, socket) do
    case Sessions.create(cwd, []) do
      {:ok, session_id} ->
        {:noreply,
         socket
         |> assign(:new_project, nil)
         |> assign_sessions()
         |> push_patch(to: ~p"/sessions/#{session_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create session: #{reason}")}
    end
  end

  def handle_event("start_new_session", params, socket) do
    cwd = Map.get(params, "cwd", default_cwd(socket))

    form = %{
      cwd: cwd,
      provider: socket.assigns.last_provider || Providers.default_name(),
      model: socket.assigns.last_model || Providers.default_model(),
      models: :loading
    }

    {:noreply, socket |> assign(:new_session, form) |> assign(:new_project, nil) |> load_models()}
  end

  def handle_event("cancel_new_session", _params, socket) do
    {:noreply, assign(socket, :new_session, nil)}
  end

  # Switching provider throws the model list away rather than filtering it: the ids are the
  # provider's own, so a model picked for one is meaningless against another.
  def handle_event("new_session_change", params, socket) do
    %{"cwd" => cwd, "provider" => provider, "model" => model} = params
    previous = socket.assigns.new_session
    switched? = provider != previous.provider

    form = %{
      previous
      | cwd: cwd,
        provider: provider,
        model: if(switched?, do: Providers.default_model(), else: model),
        models: if(switched?, do: :loading, else: previous.models)
    }

    socket = assign(socket, :new_session, form)
    {:noreply, if(switched?, do: load_models(socket), else: socket)}
  end

  def handle_event("new_session", %{"cwd" => cwd} = params, socket) do
    opts = [provider: params["provider"], model: params["model"]]

    case Sessions.create(cwd, opts) do
      {:ok, session_id} ->
        {:noreply,
         socket
         |> assign(:new_session, nil)
         |> assign(:last_model, params["model"] || Providers.default_model())
         |> assign(:last_provider, params["provider"] || Providers.default_name())
         |> assign_sessions()
         |> push_patch(to: ~p"/sessions/#{session_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create session: #{reason}")}
    end
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" or is_nil(socket.assigns.session_id) ->
        {:noreply, socket}

      true ->
        # The user's bubble is rendered from Eva's own MessageStart rather than inserted
        # optimistically, because Eva rewrites `/skill:` prompts before storing them.
        case Sessions.prompt(socket.assigns.session_id, text) do
          :ok ->
            socket =
              if socket.assigns.running?,
                do: assign(socket, :queued_messages, socket.assigns.queued_messages ++ [text]),
                else: socket

            {:noreply, push_event(socket, "chat:clear", %{})}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.session_id, do: Sessions.cancel(socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(queued_messages: [], running?: false, current_id: nil)
     |> assign_sessions()}
  end

  def handle_event("confirm_delete", %{"id" => session_id}, socket) do
    {:noreply, assign(socket, :pending_delete, Sessions.get(session_id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    viewing_it? = session_id == socket.assigns.session_id
    socket = assign(socket, :pending_delete, nil)

    case Sessions.delete(session_id) do
      :ok ->
        socket = if viewing_it?, do: push_patch(socket, to: ~p"/"), else: socket
        {:noreply, socket |> assign_sessions() |> put_flash(:info, "Session deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete session: #{reason}")}
    end
  end

  # -- Agent events --

  @impl true
  def handle_info({:eva, %Events.AgentStart{}}, socket) do
    {:noreply, assign(socket, :running?, true)}
  end

  def handle_info({:eva, %Events.AgentEnd{}}, socket) do
    {:noreply,
     socket
     |> assign(running?: false, current_id: nil)
     |> assign(:session, Sessions.get(socket.assigns.session_id))}
  end

  def handle_info(
        {:eva, %Events.MessageStart{message: %Messages.UserMessage{} = message}},
        socket
      ) do
    {id, socket} = next_id(socket)

    socket =
      case socket.assigns.queued_messages do
        [] -> socket
        [_ | rest] -> assign(socket, :queued_messages, rest)
      end

    {:noreply, stream_insert(socket, :messages, Transcript.user_item(id, message))}
  end

  def handle_info(
        {:eva, %Events.MessageStart{message: %Messages.AssistantMessage{} = message}},
        socket
      ) do
    {id, socket} = next_id(socket)

    {:noreply,
     socket
     |> assign(:current_id, id)
     |> stream_insert(:messages, Transcript.assistant_item(id, message))}
  end

  def handle_info({:eva, %Events.MessageUpdate{assistant_message_event: event}}, socket) do
    # Every provider event carries the full in-progress AssistantMessage, so the bubble is
    # re-rendered from `partial` rather than by accumulating deltas here.
    case {socket.assigns.current_id, Map.get(event, :partial)} do
      {id, %Messages.AssistantMessage{} = partial} when is_binary(id) ->
        {:noreply, stream_insert(socket, :messages, Transcript.assistant_item(id, partial))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:eva, %Events.MessageEnd{message: %Messages.AssistantMessage{} = message}},
        socket
      ) do
    id = socket.assigns.current_id

    socket =
      socket
      |> remember_tool_args(message)
      |> then(fn socket ->
        if id,
          do: stream_insert(socket, :messages, Transcript.assistant_item(id, message)),
          else: socket
      end)

    {:noreply, assign(socket, :current_id, nil)}
  end

  def handle_info({:eva, %Events.ToolExecutionStart{} = event}, socket) do
    item = Transcript.tool_started(event.tool_call_id, event.tool_name, event.args)

    {:noreply,
     socket
     |> assign(:tool_args, Map.put(socket.assigns.tool_args, event.tool_call_id, event.args))
     |> stream_insert(:messages, item)}
  end

  # ToolExecutionEnd carries no args, so they come from the start event recorded above.
  def handle_info({:eva, %Events.ToolExecutionEnd{} = event}, socket) do
    args = Map.get(socket.assigns.tool_args, event.tool_call_id)

    item =
      Transcript.tool_finished(
        event.tool_call_id,
        event.tool_name,
        args,
        event.result,
        event.is_error
      )

    {:noreply, stream_insert(socket, :messages, item)}
  end

  # Tool results arrive again as messages; the tool row above already shows them.
  def handle_info({:eva, _event}, socket), do: {:noreply, socket}

  # -- Housekeeping --

  def handle_info(:sessions_changed, socket) do
    {:noreply,
     socket
     |> assign_sessions()
     |> assign(:session, socket.assigns.session_id && Sessions.get(socket.assigns.session_id))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{monitor_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(running?: false, current_id: nil, monitor_ref: nil)
     |> put_flash(:error, "Session stopped: #{inspect(reason)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Model lookup --

  @impl true
  def handle_async(:provider_models, {:ok, {provider, result}}, socket) do
    {:noreply, apply_models(socket, provider, result)}
  end

  def handle_async(:provider_models, {:exit, reason}, socket) do
    case socket.assigns.new_session do
      %{models: :loading} = form ->
        failed = {:error, "Model lookup failed: #{inspect(reason)}"}
        {:noreply, assign(socket, :new_session, %{form | models: failed})}

      _other ->
        {:noreply, socket}
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:sidebar>
        <.sidebar
          groups={@groups}
          running_ids={@running_ids}
          active_id={@session_id}
          providers={@providers}
          new_session={@new_session}
          new_project={@new_project}
        />
      </:sidebar>

      <header class="flex h-12 shrink-0 items-center gap-3 border-b border-zinc-800 px-4">
        <%= if @session do %>
          <span class="truncate text-sm font-medium text-zinc-200">
            {@session.title || "Untitled session"}
          </span>
          <span class="truncate text-xs text-zinc-600" title={@session.cwd}>{@session.cwd}</span>
          <span class="ml-auto flex shrink-0 items-center gap-1.5">
            <span
              :if={Providers.label(@session.provider_name)}
              class="border border-zinc-800 px-2 py-0.5 text-[10px] text-zinc-600"
            >
              {Providers.label(@session.provider_name)}
            </span>
            <span class="border border-zinc-800 px-2 py-0.5 text-[10px] text-zinc-500">
              {@session.model}
            </span>
          </span>
        <% else %>
          <span class="text-sm font-medium text-zinc-500">No session selected</span>
        <% end %>
      </header>

      <div
        :if={@session_id}
        id="messages"
        phx-update="stream"
        phx-hook="ScrollToBottom"
        class="flex-1 overflow-y-auto py-4"
      >
        <div :for={{dom_id, item} <- @streams.messages} id={dom_id}>
          <.message item={item} />
        </div>
      </div>

      <div :if={is_nil(@session_id)} class="flex flex-1 items-center justify-center px-4">
        <div class="text-center">
          <p class="text-sm text-zinc-500">Pick a session, or start a new one.</p>
          <button
            type="button"
            phx-click="start_new_session"
            class="mt-4 border border-zinc-700 px-4 py-2 text-sm text-zinc-300 transition-colors hover:border-zinc-500 hover:text-zinc-100"
          >
            New session
          </button>
        </div>
      </div>

      <div
        :if={@queued_messages != []}
        class="shrink-0 border-t border-zinc-800 bg-[#0c0c0c] px-4 py-2"
      >
        <div class="mx-auto flex max-w-3xl flex-col gap-1.5">
          <div :for={msg <- @queued_messages} class="flex items-center gap-2 text-sm text-zinc-500">
            <.icon name="hero-arrow-path-mini" class="size-3.5 shrink-0 animate-spin text-zinc-600" />
            <span class="truncate">{msg}</span>
          </div>
        </div>
      </div>

      <.composer running={@running?} disabled={is_nil(@session_id)} />
      <.delete_modal session={@pending_delete} />
    </Layouts.app>
    """
  end

  # -- Private --

  defp open_session(socket, session_id) do
    socket = close_session(socket)

    with {:ok, pid} <- Sessions.ensure_started(session_id),
         {:ok, %{messages: messages, running?: running?}} <- Sessions.snapshot(session_id) do
      Sessions.subscribe(session_id)
      items = Transcript.to_items(messages)
      session = Sessions.get(session_id)

      socket
      |> assign(
        session: session,
        session_id: session_id,
        running?: running?,
        current_id: nil,
        next_index: length(items),
        tool_args: tool_args(messages),
        monitor_ref: Process.monitor(pid),
        page_title: session.title || "Eva",
        last_model: session.model,
        last_provider: session.provider_name
      )
      |> assign_sessions()
      |> stream(:messages, items, reset: true)
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not open session: #{describe(reason)}")
        |> push_patch(to: ~p"/")
    end
  end

  defp describe({%{__struct__: _} = exception, _stacktrace}), do: Exception.message(exception)
  defp describe({reason, _stacktrace}), do: inspect(reason)
  defp describe(reason), do: inspect(reason)

  defp close_session(socket) do
    if socket.assigns[:session_id], do: Sessions.unsubscribe(socket.assigns.session_id)
    if socket.assigns[:monitor_ref], do: Process.demonitor(socket.assigns.monitor_ref, [:flush])

    socket
    |> assign(
      session: nil,
      session_id: nil,
      running?: false,
      current_id: nil,
      next_index: 0,
      tool_args: %{},
      monitor_ref: nil,
      page_title: "Eva",
      queued_messages: []
    )
    |> stream(:messages, [], reset: true)
  end

  defp assign_sessions(socket) do
    assign(socket, groups: Sessions.list_grouped(), running_ids: Sessions.running_ids())
  end

  # A network call, so off the LiveView process. One async name means switching provider twice in a
  # row cancels the first lookup, and the provider rides along in the reply so a result that
  # arrives after the user moved on can be recognised as stale.
  defp load_models(socket) do
    provider = socket.assigns.new_session.provider
    start_async(socket, :provider_models, fn -> {provider, Providers.list_models(provider)} end)
  end

  # The form may have been closed, or switched to another provider, while the lookup was in
  # flight — an answer nobody is looking at any more is dropped.
  defp apply_models(
         %{assigns: %{new_session: %{provider: provider} = form}} = socket,
         provider,
         result
       ) do
    assign(socket, :new_session, %{form | models: result, model: choose_model(result, form.model)})
  end

  defp apply_models(socket, _provider, _result), do: socket

  # Keeps what's in the field when the provider actually offers it, so a configured default
  # survives; otherwise the picker has to land on something the provider will accept.
  defp choose_model({:ok, models}, current) do
    cond do
      current in models -> current
      models == [] -> current
      true -> hd(models)
    end
  end

  defp choose_model({:error, _reason}, current), do: current

  defp next_id(socket) do
    index = socket.assigns.next_index
    {Transcript.message_id(index), assign(socket, :next_index, index + 1)}
  end

  # ToolExecutionEnd carries args already, but keeping the call's own arguments means a replayed
  # row and a live one show exactly the same thing.
  defp remember_tool_args(socket, %Messages.AssistantMessage{} = message) do
    args =
      message
      |> Messages.AssistantMessage.tool_calls()
      |> Map.new(&{&1.id, &1.arguments})

    assign(socket, :tool_args, Map.merge(socket.assigns.tool_args, args))
  end

  defp tool_args(messages) do
    for %Messages.AssistantMessage{} = message <- messages,
        tool_call <- Messages.AssistantMessage.tool_calls(message),
        into: %{},
        do: {tool_call.id, tool_call.arguments}
  end

  defp default_cwd(socket) do
    case socket.assigns.session do
      %{cwd: cwd} when is_binary(cwd) -> cwd
      _ -> File.cwd!()
    end
  end
end
