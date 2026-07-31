defmodule EvaWebWeb.ChatLive do
  @moduledoc """
  The chat UI: session list, session switching, and a live transcript.

  Session state lives in `EvaWeb.Sessions.Runner`, not here. On mount (and on every reconnect or
  session switch) this view pulls a snapshot and re-streams it, then applies agent events as they
  arrive over PubSub. It never reloads history mid-conversation — doing that on `AgentStart` is what
  used to duplicate the whole transcript on every turn.
  """
  use EvaWebWeb, :live_view

  require Logger

  import EvaWebWeb.ChatComponents

  alias Eva.Agent.Events
  alias Eva.Agent.Messages
  alias EvaWeb.Fonts
  alias EvaWeb.Providers
  alias EvaWeb.Sessions
  alias EvaWeb.Sessions.Ledger
  alias EvaWeb.Sessions.MCP
  alias EvaWeb.Sessions.Transcript
  alias EvaWeb.Settings

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
       current_at: nil,
       next_index: 0,
       tool_args: %{},
       monitor_ref: nil,
       pending_delete: nil,
       providers: Providers.all(),
       new_session: nil,
       new_project: nil,
       queued_messages: [],
       last_model: nil,
       last_provider: nil,
       mcp: MCP.empty(),
       show_mcp: false,
       renaming: false,
       rename_form: nil,
       user_rows: [],
       prefill: nil,
       mode: :prompt,
       pending_bash: nil,
       deferred: [],
       settings: Settings.get(),
       show_settings: false,
       fonts: :loading
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

  def handle_event("browse_project_dir", _, socket) do
    case pick_directory() do
      nil -> {:noreply, socket}
      path -> {:noreply, assign(socket, :new_project, %{cwd: path})}
    end
  end

  def handle_event("new_project", %{"cwd" => cwd}, socket) do
    cwd = Path.expand(cwd)

    if File.dir?(cwd) do
      form = %{
        cwd: cwd,
        provider: socket.assigns.last_provider || Providers.default_name(),
        model: socket.assigns.last_model,
        models: :loading
      }

      {:noreply,
       socket
       |> assign(:new_project, nil)
       |> assign(:new_session, form)
       |> load_models()}
    else
      {:noreply, put_flash(socket, :error, "#{cwd} is not a directory")}
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

      socket.assigns.mode != :prompt ->
        {:noreply, run_command(socket, text)}

      # Eva would take this and park it in the harness queue until some future turn, where it
      # would sit invisibly. Holding it here means it goes when the command is done and not before.
      socket.assigns.pending_bash ->
        {:noreply,
         socket
         |> assign(:deferred, socket.assigns.deferred ++ [text])
         |> push_event("chat:clear", %{})}

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

          # Eva answers with a sentence; a dead or wedged runner answers with an exit reason.
          {:error, reason} when is_binary(reason) ->
            {:noreply, put_flash(socket, :error, reason)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not send: #{describe(reason)}")}
        end
    end
  end

  # Forking leaves this session untouched and opens the new one, because that is where the work
  # continues — the fork it just gained is linked from the message on the way back.
  def handle_event("fork", %{"entry" => entry_id}, socket) do
    case Sessions.fork(socket.assigns.session_id, entry_id) do
      {:ok, %{session_id: forked_id, prefill: prefill}} ->
        {:noreply,
         socket
         |> assign(:prefill, {forked_id, prefill})
         |> assign_sessions()
         |> push_patch(to: ~p"/sessions/#{forked_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not fork: #{describe(reason)}")}
    end
  end

  # -- Composer modes --

  # The keyboard drives this from the ChatInput hook (`!` to descend, backspace on an empty box and
  # escape to come back), and the pill is the same thing for people who would rather click.
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :mode, parse_mode(mode))}
  end

  def handle_event("cycle_mode", _params, socket) do
    next =
      case socket.assigns.mode do
        :prompt -> :command
        :command -> :private_command
        :private_command -> :prompt
      end

    {:noreply, socket |> assign(:mode, next) |> push_event("chat:focus", %{})}
  end

  # The command still comes back — Eva reports a killed one with `cancelled: true` and whatever it
  # printed — so the row finishes the ordinary way and there is nothing to tidy up here.
  def handle_event("cancel_bash", _params, socket) do
    case Sessions.cancel_bash(socket.assigns.session_id) do
      :ok ->
        {:noreply, socket}

      {:error, :no_command_running} ->
        {:noreply, assign(socket, :pending_bash, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not stop: #{describe(reason)}")}
    end
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.session_id, do: Sessions.cancel(socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(queued_messages: [], running?: false, current_id: nil, current_at: nil)
     |> assign_sessions()}
  end

  # -- Settings --

  # Enumerating fonts shells out, so it happens off the LiveView process and only when the modal
  # is actually opened. It is cached after the first read, so reopening is instant.
  def handle_event("open_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(show_settings: true, settings: Settings.get())
     |> load_fonts(&Fonts.list/0)}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  def handle_event("rescan_fonts", _params, socket) do
    {:noreply, load_fonts(socket, &Fonts.refresh/0)}
  end

  # The form change event carries every field each time, so only what actually moved is written —
  # otherwise picking a UI font rewrites the settings file for the mono one too.
  def handle_event("settings_change", params, socket) do
    settings =
      Enum.reduce([:ui_font, :mono_font, :font_scale], socket.assigns.settings, fn key, acc ->
        picked = presence(params[Atom.to_string(key)])

        if same?(picked, Map.fetch!(acc, key)), do: acc, else: Settings.put(key, picked)
      end)

    {:noreply, assign(socket, :settings, settings)}
  end

  def handle_event("toggle_mcp", _params, socket) do
    {:noreply, assign(socket, :show_mcp, not socket.assigns.show_mcp)}
  end

  def handle_event("close_mcp", _params, socket) do
    {:noreply, assign(socket, :show_mcp, false)}
  end

  # The runner publishes the new state to everyone on the session, this view included, so there is
  # nothing to assign here beyond reporting a refusal.
  def handle_event("mcp_set_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    {:noreply, set_mcp_enabled(socket, name, enabled == "true", :session)}
  end

  def handle_event("mcp_persist", %{"name" => name, "enabled" => enabled}, socket) do
    {:noreply, set_mcp_enabled(socket, name, enabled == "true", :persist)}
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

  def handle_event("start_rename", _params, socket) do
    current = socket.assigns.session.title || ""
    {:noreply, assign(socket, renaming: true, rename_form: to_form(%{"name" => current}))}
  end

  def handle_event("rename_change", %{"name" => name}, socket) do
    {:noreply, assign(socket, :rename_form, to_form(%{"name" => name}))}
  end

  def handle_event("save_rename", %{"name" => name}, socket) do
    name = String.trim(name)
    session_id = socket.assigns.session_id

    cond do
      name == "" ->
        {:noreply, assign(socket, :renaming, false)}

      true ->
        Sessions.rename(session_id, name)

        {:noreply,
         socket
         |> assign(renaming: false, rename_form: nil)
         |> assign(:session, Sessions.get(session_id))
         |> assign(page_title: name)}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming: false, rename_form: nil)}
  end

  # -- Agent events --

  @impl true
  def handle_info({:eva, %Events.AgentStart{}}, socket) do
    {:noreply, assign(socket, :running?, true)}
  end

  def handle_info({:eva, %Events.AgentEnd{}}, socket) do
    {:noreply,
     socket
     |> assign(running?: false, current_id: nil, current_at: nil)
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

    # Tracked in order alongside the stream: this is the row a fork handle lands on once Eva has
    # written the message and the runner says which entry it became.
    item = Transcript.user_item(id, message, Transcript.now())

    {:noreply,
     socket
     |> assign(:user_rows, socket.assigns.user_rows ++ [item])
     |> stream_insert(:messages, item)}
  end

  # Eva announces a `!` command when it starts it, not when it finishes — this is the row that
  # stands in until the output arrives, in every window rather than only the one that ran it.
  def handle_info(
        {:eva, %Events.MessageStart{message: %Messages.BashExecutionMessage{} = message}},
        socket
      ) do
    {id, socket} = next_id(socket)
    item = Transcript.bash_started(id, message.command, message.exclude_from_context)

    {:noreply, socket |> assign(:pending_bash, id) |> stream_insert(:messages, item)}
  end

  def handle_info(
        {:eva, %Events.MessageStart{message: %Messages.AssistantMessage{} = message}},
        socket
      ) do
    {id, socket} = next_id(socket)
    # Stamped once, when the reply starts, and carried through every delta after it: a row that
    # re-dated itself on each token would count up while the reader watched.
    at = Transcript.now()

    {:noreply,
     socket
     |> assign(current_id: id, current_at: at)
     |> stream_insert(:messages, Transcript.assistant_item(id, message, at))}
  end

  def handle_info({:eva, %Events.MessageUpdate{assistant_message_event: event}}, socket) do
    # Every provider event carries the full in-progress AssistantMessage, so the bubble is
    # re-rendered from `partial` rather than by accumulating deltas here.
    case {socket.assigns.current_id, Map.get(event, :partial)} do
      {id, %Messages.AssistantMessage{} = partial} when is_binary(id) ->
        item = Transcript.assistant_item(id, partial, socket.assigns.current_at)
        {:noreply, stream_insert(socket, :messages, item)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:eva, %Events.MessageEnd{message: %Messages.AssistantMessage{} = message}},
        socket
      ) do
    id = socket.assigns.current_id
    at = socket.assigns.current_at

    socket =
      socket
      |> remember_tool_args(message)
      |> then(fn socket ->
        if id,
          do: stream_insert(socket, :messages, Transcript.assistant_item(id, message, at)),
          else: socket
      end)

    {:noreply, assign(socket, current_id: nil, current_at: nil)}
  end

  def handle_info({:eva, %Events.ToolExecutionStart{} = event}, socket) do
    item = Transcript.tool_started(event.tool_call_id, event.tool_name, event.args)

    {:noreply,
     socket
     |> assign(:tool_args, Map.put(socket.assigns.tool_args, event.tool_call_id, event.args))
     |> stream_insert(:messages, item)}
  end

  # A running tool reporting where it has got to — MCP servers send these as progress
  # notifications. The row is rebuilt rather than patched because streams are write-only, so the
  # args come from the start event recorded above.
  def handle_info({:eva, %Events.ToolExecutionUpdate{} = event}, socket) do
    case progress_text(event.partial_result) do
      nil ->
        {:noreply, socket}

      progress ->
        args = Map.get(socket.assigns.tool_args, event.tool_call_id)
        item = Transcript.tool_started(event.tool_call_id, event.tool_name, args, progress)
        {:noreply, stream_insert(socket, :messages, item)}
    end
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

  # A command Eva has finished with. It arrives as an ordinary message event, so every view
  # watching the session gets the row — not just the one whose composer ran it. The optimistic
  # row this replaces is claimed by id, so the two never both appear.
  def handle_info(
        {:eva, %Events.MessageEnd{message: %Messages.BashExecutionMessage{} = message}},
        socket
      ) do
    {id, socket} =
      case socket.assigns.pending_bash do
        nil -> next_id(socket)
        id -> {id, assign(socket, :pending_bash, nil)}
      end

    {:noreply,
     socket
     |> stream_insert(:messages, Transcript.bash_finished(id, message))
     |> flush_deferred()}
  end

  # Tool results arrive again as messages; the tool row above already shows them.
  def handle_info({:eva, _event}, socket), do: {:noreply, socket}

  # The runner derives MCP state from Eva's own server list and publishes it whole, so there is
  # nothing to fold here — and every view watching the session sees the same thing after a toggle.
  def handle_info({:mcp, mcp}, socket), do: {:noreply, assign(socket, :mcp, mcp)}

  # Fork state is derived from the transcript on disk, so it lands a beat behind the message it
  # belongs to, and again whenever a fork is taken from this session in any window.
  def handle_info({:ledger, ledger}, socket), do: {:noreply, apply_forks(socket, ledger)}

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
     |> assign(running?: false, current_id: nil, current_at: nil, monitor_ref: nil)
     |> put_flash(:error, "Session stopped: #{inspect(reason)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Model lookup --

  @impl true
  def handle_async(:fonts, {:ok, families}, socket) do
    {:noreply, assign(socket, :fonts, families)}
  end

  # A machine with no fontconfig and a broken fallback would leave the picker permanently empty;
  # showing the built-in list is better than a modal that never resolves.
  def handle_async(:fonts, {:exit, reason}, socket) do
    Logger.warning("ChatLive: font lookup failed: #{inspect(reason)}")
    {:noreply, assign(socket, :fonts, %{ui: [], mono: []})}
  end

  # The row itself comes from Eva's event, so all that is left here is the refusal — and clearing
  # the placeholder row, which would otherwise spin forever on a command that never ran.
  def handle_async(:run_bash, {:ok, {:error, reason}}, socket) do
    {:noreply, drop_pending_bash(socket, describe_bash_error(reason))}
  end

  def handle_async(:run_bash, {:ok, _result}, socket), do: {:noreply, socket}

  def handle_async(:run_bash, {:exit, reason}, socket) do
    {:noreply, drop_pending_bash(socket, "Command failed: #{describe(reason)}")}
  end

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
    <Layouts.app flash={@flash} settings={@settings}>
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

      <div class="relative flex min-h-0 flex-1">
        <div class="flex min-w-0 flex-1 flex-col">
          <header class="flex h-12 shrink-0 items-center gap-3 border-b border-zinc-800 px-4">
            <%= if @session do %>
              <%= if @renaming do %>
                <.form
                  for={@rename_form}
                  id="rename-form"
                  phx-change="rename_change"
                  phx-submit="save_rename"
                  class="flex items-center gap-1.5"
                >
                  <input
                    type="text"
                    name="name"
                    value={@rename_form[:name].value}
                    class="w-48 rounded border border-zinc-700 bg-[#0c0c0c] px-2 py-1 text-sm text-zinc-200 outline-none transition-colors focus:border-zinc-500"
                    phx-blur="cancel_rename"
                    autofocus
                  />
                  <button
                    type="submit"
                    class="shrink-0 text-zinc-500 hover:text-zinc-300 transition-colors"
                  >
                    <.icon name="hero-check-mini" class="size-4" />
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_rename"
                    class="shrink-0 text-zinc-500 hover:text-zinc-300 transition-colors"
                  >
                    <.icon name="hero-x-mark-mini" class="size-4" />
                  </button>
                </.form>
              <% else %>
                <button
                  phx-click="start_rename"
                  class="group flex items-center gap-1.5 min-w-0"
                  title="Rename session"
                >
                  <span class="truncate text-sm font-medium text-zinc-200 group-hover:text-zinc-100 transition-colors">
                    {@session.title || "Untitled session"}
                  </span>
                  <.icon
                    name="hero-pencil-mini"
                    class="size-3.5 shrink-0 text-zinc-700 opacity-0 transition-opacity group-hover:opacity-100"
                  />
                </button>
              <% end %>
              <span class="truncate text-xs text-zinc-600" title={@session.cwd}>{@session.cwd}</span>
              <span class="ml-auto flex shrink-0 items-center gap-1.5">
                <.mcp_indicator mcp={@mcp} open={@show_mcp} />
                <span
                  :if={Providers.label(@session.provider_name)}
                  class="border border-zinc-800 px-2 py-0.5 text-3xs text-zinc-600"
                >
                  {Providers.label(@session.provider_name)}
                </span>
                <span class="border border-zinc-800 px-2 py-0.5 text-3xs text-zinc-500">
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
            :if={@queued_messages != [] or @deferred != []}
            class="shrink-0 border-t border-zinc-800 bg-[#0c0c0c] px-4 py-2"
          >
            <div class="mx-auto flex max-w-3xl flex-col gap-1.5">
              <div
                :for={msg <- @queued_messages ++ @deferred}
                class="flex items-center gap-2 text-sm text-zinc-500"
              >
                <.icon
                  name="hero-arrow-path-mini"
                  class="size-3.5 shrink-0 animate-spin text-zinc-600"
                />
                <span class="truncate">{msg}</span>
              </div>
            </div>
          </div>

          <.composer
            running={@running?}
            disabled={is_nil(@session_id)}
            mode={@mode}
            command_running={not is_nil(@pending_bash)}
          />
        </div>

        <.mcp_panel mcp={@mcp} open={@show_mcp and not is_nil(@session_id)} />
      </div>

      <.delete_modal session={@pending_delete} />
      <.settings_modal open={@show_settings} settings={@settings} fonts={@fonts} />
    </Layouts.app>
    """
  end

  # -- Private --

  defp open_session(socket, session_id) do
    socket = close_session(socket)

    with {:ok, pid} <- Sessions.ensure_started(session_id),
         {:ok, %{messages: messages, running?: running?, mcp: mcp, ledger: ledger} = snapshot} <-
           Sessions.snapshot(session_id) do
      Sessions.subscribe(session_id)
      items = Transcript.to_items(messages, ledger)
      user_rows = Enum.filter(items, &(&1.kind == :user))
      session = Sessions.get(session_id)

      socket
      |> assign(
        session: session,
        session_id: session_id,
        running?: running?,
        current_id: nil,
        current_at: nil,
        # Counted in messages, not rows. Ids are the message's own index, and rows are fewer —
        # tool results are keyed by call id and empty assistant messages render as nothing — so
        # starting from the row count hands the next live row an id a replayed one already holds,
        # and the stream overwrites that row instead of appending.
        next_index: length(messages),
        tool_args: tool_args(messages),
        monitor_ref: Process.monitor(pid),
        page_title: session.title || "Eva",
        mcp: mcp,
        user_rows: user_rows
      )
      |> assign_sessions()
      |> stream(:messages, items, reset: true)
      |> restore_command(snapshot.command)
      |> maybe_prefill(session_id)
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
      current_at: nil,
      next_index: 0,
      tool_args: %{},
      monitor_ref: nil,
      page_title: "Eva",
      queued_messages: [],
      renaming: false,
      rename_form: nil,
      mcp: MCP.empty(),
      show_mcp: false,
      user_rows: [],
      mode: :prompt,
      pending_bash: nil,
      deferred: []
    )
    |> stream(:messages, [], reset: true)
  end

  # -- Commands --

  # Off the LiveView process: Eva answers only when the command is done, and waiting inline would
  # freeze this view — no scrolling, no switching sessions, not even the stop button — for as long
  # as it runs. The row itself comes from Eva's `MessageStart`, so every window gets one.
  defp run_command(socket, command) do
    private? = socket.assigns.mode == :private_command
    session_id = socket.assigns.session_id

    socket
    |> assign(:mode, :prompt)
    |> push_event("chat:clear", %{})
    |> start_async(:run_bash, fn ->
      Sessions.run_bash(session_id, command, exclude_from_context: private?)
    end)
  end

  # A view opened while a command is running still has to show it, and the button that stops it —
  # the row only reaches the transcript when the command ends, which may be minutes away.
  defp restore_command(socket, nil), do: socket

  defp restore_command(socket, command) do
    {id, socket} = next_id(socket)

    socket
    |> assign(:pending_bash, id)
    |> stream_insert(:messages, Transcript.bash_started(id, command, false))
  end

  # Sends what was typed while the command ran, in the order it was typed. The first one starts a
  # turn and the rest queue behind it as follow-ups, which is what the strip above the composer is
  # already there to show.
  defp flush_deferred(%{assigns: %{deferred: []}} = socket), do: socket

  defp flush_deferred(socket) do
    texts = socket.assigns.deferred

    failed =
      Enum.filter(texts, fn text ->
        match?({:error, _reason}, Sessions.prompt(socket.assigns.session_id, text))
      end)

    socket
    |> assign(deferred: [], queued_messages: socket.assigns.queued_messages ++ (texts -- failed))
    |> then(fn socket ->
      if failed == [],
        do: socket,
        else: put_flash(socket, :error, "Could not send #{length(failed)} queued message(s).")
    end)
  end

  # Nothing ran, so the placeholder row is a lie — but a stream row can only be replaced, not
  # withdrawn by assigning around it, so it is deleted outright.
  defp drop_pending_bash(socket, message) do
    socket =
      case socket.assigns.pending_bash do
        nil -> socket
        id -> stream_delete_by_dom_id(socket, :messages, "messages-#{id}")
      end

    socket |> assign(:pending_bash, nil) |> put_flash(:error, message)
  end

  defp describe_bash_error(:agent_running), do: "Eva is working — let the turn finish first."
  defp describe_bash_error(:bash_running), do: "A command is already running."
  defp describe_bash_error(reason), do: "Command failed: #{describe(reason)}"

  defp parse_mode("command"), do: :command
  defp parse_mode("private_command"), do: :private_command
  defp parse_mode(_mode), do: :prompt

  # -- Forks --

  # The nth user bubble on screen is the nth user message in the transcript, so fork state is
  # matched to rows by position: the ids the stream runs on are this view's own and mean nothing to
  # Eva. Rows past the end of the ledger are messages Eva hasn't stored yet — they get their fork
  # handle when the transcript catches up.
  defp with_forks(user_rows, ledger) do
    fork_points = Ledger.fork_points(ledger)

    user_rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      entry_id = Enum.at(fork_points, index)
      %{row | entry_id: entry_id, forks: Ledger.forks_at(ledger, entry_id)}
    end)
  end

  # Streams render what they are handed and nothing else, so a row whose forks changed has to go
  # back in. Untouched rows are left alone rather than re-sent as a block: re-inserting the whole
  # transcript on every message would undo the reader's scroll position and collapse open tools.
  defp apply_forks(socket, ledger) do
    updated = with_forks(socket.assigns.user_rows, ledger)

    socket.assigns.user_rows
    |> Enum.zip(updated)
    |> Enum.reduce(assign(socket, :user_rows, updated), fn
      {same, same}, socket -> socket
      {_before, row}, socket -> stream_insert(socket, :messages, row)
    end)
  end

  # The message a fork was taken at is handed back rather than replayed: the new session stops just
  # short of it, so it belongs in the composer where the user can rework it before sending.
  defp maybe_prefill(socket, session_id) do
    case socket.assigns.prefill do
      {^session_id, text} ->
        socket
        |> assign(:prefill, nil)
        |> push_event("chat:fill", %{text: text})

      _other ->
        socket
    end
  end

  defp assign_sessions(socket) do
    assign(socket, groups: Sessions.list_grouped(), running_ids: Sessions.running_ids())
  end

  defp set_mcp_enabled(%{assigns: %{session_id: nil}} = socket, _name, _enabled?, _scope) do
    socket
  end

  defp set_mcp_enabled(socket, name, enabled?, scope) do
    case Sessions.set_mcp_enabled(socket.assigns.session_id, name, enabled?, scope) do
      :ok ->
        socket

      {:error, reason} ->
        put_flash(socket, :error, "Could not update #{name}: #{describe(reason)}")
    end
  end

  defp load_fonts(socket, read) do
    start_async(socket, :fonts, read)
  end

  # Every value arrives from the form as a string, including the font scale, which is stored as an
  # integer — so "110" and 110 are the same choice and must not look like a change.
  defp same?(picked, current) when is_integer(current), do: picked == to_string(current)
  defp same?(picked, current), do: picked == current

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

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

  # Partial results carry the same content shape as a finished one; only the text is useful as a
  # status line, and an empty one is not worth re-rendering the row for.
  defp progress_text(%{content: content}) do
    case content |> Messages.content_text() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp progress_text(_partial_result), do: nil

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

  defp pick_directory do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("osascript", [
               "-e",
               ~s'POSIX path of (choose folder with prompt "Select project directory")'
             ]) do
          {path, 0} -> String.trim(path)
          _ -> nil
        end

      {:unix, _} ->
        case System.cmd("which", ["zenity"], stderr_to_stdout: true) do
          {_, 0} ->
            case System.cmd("zenity", [
                   "--file-selection",
                   "--directory",
                   "--title=Select project directory"
                 ]) do
              {path, 0} -> String.trim(path)
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp default_cwd(socket) do
    case socket.assigns.session do
      %{cwd: cwd} when is_binary(cwd) -> cwd
      _ -> File.cwd!()
    end
  end
end
