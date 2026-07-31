defmodule EvaWebWeb.ChatComponents do
  @moduledoc """
  Presentational pieces of the chat UI: the session sidebar, transcript rows, and the composer.
  """
  use EvaWebWeb, :html

  alias EvaWeb.Sessions.MCP
  alias EvaWeb.Sessions.Transcript

  # Syntect ships its own themes (from the Rust two-face crate) and emits inline styles, so the
  # colours come from MDEx rather than being hand-rolled here. Names are two-face's own and an
  # unknown one panics the NIF rather than falling back, so this is not a free-text setting.
  # Requires `config :mdex_native, syntax_highlighter: :syntect`, read at NIF compile time.
  @code_theme "gruvbox-dark"

  @doc "Session list, grouped by project directory."
  attr :groups, :list, required: true
  attr :running_ids, :any, required: true
  attr :active_id, :string, default: nil
  attr :providers, :list, default: []
  attr :new_session, :map, default: nil
  attr :new_project, :map, default: nil

  def sidebar(assigns) do
    ~H"""
    <div class="flex h-12 shrink-0 items-center justify-between border-b border-zinc-800 px-4">
      <span class="text-sm font-semibold tracking-wide text-zinc-300">Eva</span>
      <div class="flex items-center gap-1.5">
        <button
          id="open-settings"
          type="button"
          phx-click="open_settings"
          title="Settings"
          aria-label="Settings"
          class="flex size-7 items-center justify-center border border-zinc-800 text-zinc-500 transition-colors hover:border-zinc-500 hover:text-zinc-100"
        >
          <.icon name="hero-cog-6-tooth-mini" class="size-4" />
        </button>
        <button
          id="new-project"
          type="button"
          phx-click={
            cond do
              @new_project -> "cancel_new_project"
              @new_session -> "cancel_new_session"
              true -> "start_new_project"
            end
          }
          title={if @new_project || @new_session, do: "Cancel", else: "New project"}
          class="flex size-7 items-center justify-center border border-zinc-700 text-zinc-400 transition-colors hover:border-zinc-500 hover:text-zinc-100"
        >
          <.icon
            name={if @new_project || @new_session, do: "hero-x-mark-mini", else: "hero-plus-mini"}
            class="size-4"
          />
        </button>
      </div>
    </div>

    <%!-- New project form: just a directory path. --%>
    <form
      :if={@new_project}
      id="new-project-form"
      phx-change="new_project_change"
      phx-submit="new_project"
      class="space-y-3 border-b border-zinc-800 px-4 py-3"
    >
      <div>
        <label for="new-project-cwd" class="text-3xs uppercase tracking-wider text-zinc-600">
          Project directory
        </label>
        <div class="mt-1 flex gap-1">
          <input
            id="new-project-cwd"
            type="text"
            name="cwd"
            value={@new_project.cwd}
            autocomplete="off"
            spellcheck="false"
            class="flex-1 border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
          />
          <button
            type="button"
            phx-click="browse_project_dir"
            title="Browse…"
            class="flex shrink-0 items-center border border-zinc-700 px-2 text-zinc-500 transition-colors hover:border-zinc-500 hover:text-zinc-300"
          >
            <.icon name="hero-folder-open-mini" class="size-3.5" />
          </button>
        </div>
      </div>
      <button
        type="submit"
        class="w-full bg-[#116a34b5] px-2 py-1 text-xs text-white transition-colors hover:bg-[#116a34]"
      >
        Open project
      </button>
    </form>

    <%!-- Standalone session form when no project group matches the cwd. --%>
    <form
      :if={@new_session && not Enum.any?(@groups, &(&1.cwd == @new_session.cwd))}
      id="new-session-form"
      phx-change="new_session_change"
      phx-submit="new_session"
      class="space-y-3 border-b border-zinc-800 px-4 py-3"
    >
      <div class="flex items-center justify-between">
        <span class="truncate text-3xs font-medium uppercase tracking-wider text-zinc-500">
          {Path.basename(@new_session.cwd)}
        </span>
        <button
          type="button"
          phx-click="cancel_new_session"
          title="Cancel"
          class="ml-2 shrink-0 text-zinc-600 hover:text-zinc-300"
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" />
        </button>
      </div>
      <input type="hidden" name="cwd" value={@new_session.cwd} />
      <div>
        <label for="new-session-provider" class="text-3xs uppercase tracking-wider text-zinc-600">
          Provider
        </label>
        <select
          id="new-session-provider"
          name="provider"
          class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
        >
          <option
            :for={provider <- @providers}
            value={provider.name}
            selected={provider.name == @new_session.provider}
            class="bg-zinc-900"
          >
            {provider.label}
          </option>
        </select>
      </div>
      <div>
        <label for="new-session-model" class="text-3xs uppercase tracking-wider text-zinc-600">
          Model
        </label>
        <.model_field new_session={@new_session} />
      </div>
      <button
        type="submit"
        class="w-full bg-[#116a34b5] px-2 py-1 text-xs text-white transition-colors hover:bg-[#116a34]"
      >
        Create session
      </button>
    </form>

    <nav id="session-list" class="flex-1 overflow-y-auto py-2">
      <p :if={@groups == []} class="px-4 py-6 text-xs text-zinc-600">
        No sessions yet. Start one with the + button.
      </p>

      <section :for={group <- @groups} class="mb-3">
        <h3 class="group flex items-center justify-between px-4 py-1">
          <span
            class="truncate text-3xs font-semibold uppercase tracking-wider text-zinc-600"
            title={group.cwd}
          >
            {group.label}
          </span>
          <button
            type="button"
            phx-click={
              if @new_session && @new_session.cwd == group.cwd,
                do: "cancel_new_session",
                else: "start_new_session"
            }
            phx-value-cwd={group.cwd}
            title={
              if @new_session && @new_session.cwd == group.cwd,
                do: "Cancel",
                else: "New session"
            }
            class="ml-1 flex size-5 shrink-0 items-center justify-center text-zinc-700 opacity-0 transition hover:text-zinc-300 group-hover:opacity-100"
          >
            <.icon
              name={
                if @new_session && @new_session.cwd == group.cwd,
                  do: "hero-x-mark-mini",
                  else: "hero-plus-mini"
              }
              class="size-3"
            />
          </button>
        </h3>

        <%!-- Inline new-session form for this project. --%>
        <form
          :if={@new_session && @new_session.cwd == group.cwd}
          id="new-session-form"
          phx-change="new_session_change"
          phx-submit="new_session"
          class="space-y-2 border-b border-zinc-800/50 px-4 pb-3"
        >
          <input type="hidden" name="cwd" value={@new_session.cwd} />
          <div>
            <label
              for="new-session-provider"
              class="text-3xs uppercase tracking-wider text-zinc-600"
            >
              Provider
            </label>
            <select
              id="new-session-provider"
              name="provider"
              class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
            >
              <option
                :for={provider <- @providers}
                value={provider.name}
                selected={provider.name == @new_session.provider}
                class="bg-zinc-900"
              >
                {provider.label}
              </option>
            </select>
          </div>
          <div>
            <label for="new-session-model" class="text-3xs uppercase tracking-wider text-zinc-600">
              Model
            </label>
            <.model_field new_session={@new_session} />
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="cancel_new_session"
              class="flex-1 border border-zinc-700 px-2 py-1 text-xs text-zinc-400 transition-colors hover:border-zinc-500 hover:text-zinc-200"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="flex-1 bg-[#116a34b5] px-2 py-1 text-xs text-white transition-colors hover:bg-[#116a34]"
            >
              Create
            </button>
          </div>
        </form>

        <div
          :for={session <- group.sessions}
          id={"session-#{session.id}"}
          class={[
            "group flex items-center border-l-2 transition-colors",
            if(session.id == @active_id,
              do: "border-emerald-600 bg-zinc-900",
              else: "border-transparent hover:bg-zinc-900/60"
            )
          ]}
        >
          <.link
            patch={~p"/sessions/#{session.id}"}
            class={[
              "flex min-w-0 flex-1 items-center gap-2 py-1.5 pl-4 text-sm",
              if(session.id == @active_id,
                do: "text-zinc-100",
                else: "text-zinc-400 group-hover:text-zinc-200"
              )
            ]}
          >
            <span
              :if={MapSet.member?(@running_ids, session.id)}
              class="size-1.5 shrink-0 animate-pulse rounded-full bg-emerald-500"
              title="Working"
            />
            <span class="flex-1 truncate">{session.title || "Untitled session"}</span>
            <span class="shrink-0 text-3xs text-zinc-600">
              {relative_time(session.updated_at)}
            </span>
          </.link>
          <button
            type="button"
            id={"confirm-delete-session-#{session.id}"}
            phx-click="confirm_delete"
            phx-value-id={session.id}
            title="Delete session"
            aria-label="Delete session"
            class="mr-2 flex size-6 shrink-0 items-center justify-center text-zinc-700 opacity-0 transition hover:text-red-400 focus:opacity-100 group-hover:opacity-100"
          >
            <.icon name="hero-trash-mini" class="size-3.5" />
          </button>
        </div>
      </section>
    </nav>
    """
  end

  attr :new_session, :map, required: true

  defp model_field(%{new_session: %{models: {:ok, [_ | _] = models}}} = assigns) do
    assigns = assign(assigns, :models, models)

    ~H"""
    <select
      id="new-session-model"
      name="model"
      class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
    >
      <option
        :for={model <- @models}
        value={model}
        selected={model == @new_session.model}
        class="bg-zinc-900"
      >
        {model}
      </option>
    </select>
    """
  end

  # A provider that can't be reached is normal here — LM Studio may simply not be running, and the
  # opencode key may be unset — so the model stays a free text field rather than an empty dropdown
  # that blocks the session from being created at all.
  defp model_field(assigns) do
    ~H"""
    <input
      id="new-session-model"
      type="text"
      name="model"
      value={@new_session.model}
      autocomplete="off"
      spellcheck="false"
      class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
    />
    <p :if={@new_session.models == :loading} class="mt-1 text-3xs text-zinc-600">
      Loading models…
    </p>
    <p
      :if={match?({:error, _reason}, @new_session.models)}
      id="new-session-model-error"
      class="mt-1 text-3xs text-amber-600/90"
    >
      {elem(@new_session.models, 1)}
    </p>
    <p :if={@new_session.models == {:ok, []}} class="mt-1 text-3xs text-zinc-600">
      Provider listed no models.
    </p>
    """
  end

  @doc """
  Confirmation for deleting a session.

  A real modal rather than a native `confirm()`: the deletion is unrecoverable, and a browser
  dialog can be suppressed by whatever client the app is embedded in — which silently turns the
  delete button into a no-op.
  """
  attr :session, :map, default: nil

  def delete_modal(assigns) do
    ~H"""
    <div
      :if={@session}
      id="delete-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="cancel_delete"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/70" phx-click="cancel_delete" aria-hidden="true" />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-modal-title"
        class="relative w-full max-w-sm border border-zinc-700 bg-[#141414] p-5 shadow-2xl"
      >
        <h2 id="delete-modal-title" class="text-sm font-semibold text-zinc-100">Delete session?</h2>
        <p class="mt-2 text-sm leading-relaxed text-zinc-400">
          <span class="text-zinc-200">{@session.title || "Untitled session"}</span>
          and its transcript will be permanently removed. This cannot be undone.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            phx-click="cancel_delete"
            class="border border-zinc-700 px-3 py-1.5 text-xs text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
          >
            Cancel
          </button>
          <button
            type="button"
            id="delete-session-confirm"
            phx-click="delete_session"
            phx-value-id={@session.id}
            class="border border-red-800 bg-red-950 px-3 py-1.5 text-xs font-medium text-red-200 transition hover:bg-red-900"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Settings, currently the two fonts the UI is drawn with.

  Changes apply as they're picked rather than on a save button: the whole point of choosing a font
  is seeing it, and the modal is sitting on top of a full page of text rendered in it.
  """
  attr :open, :boolean, default: false
  attr :settings, :map, required: true
  attr :fonts, :any, required: true

  def settings_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      id="settings-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_settings"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/70" phx-click="close_settings" aria-hidden="true" />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-modal-title"
        class="relative w-full max-w-md border border-zinc-700 bg-[#141414] shadow-2xl"
      >
        <div class="flex items-center justify-between border-b border-zinc-800 px-5 py-3">
          <h2 id="settings-modal-title" class="text-sm font-semibold text-zinc-100">Settings</h2>
          <button
            type="button"
            phx-click="close_settings"
            title="Close"
            aria-label="Close settings"
            class="flex size-6 items-center justify-center text-zinc-600 transition-colors hover:text-zinc-200"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </div>

        <form id="settings-form" phx-change="settings_change" class="space-y-4 px-5 py-4">
          <div>
            <label for="settings-ui-font" class="text-3xs uppercase tracking-wider text-zinc-600">
              UI font
            </label>
            <.font_select
              id="settings-ui-font"
              name="ui_font"
              selected={@settings.ui_font}
              families={font_options(@fonts, :ui)}
            />
          </div>

          <div>
            <label
              for="settings-mono-font"
              class="text-3xs uppercase tracking-wider text-zinc-600"
            >
              Mono font
            </label>
            <.font_select
              id="settings-mono-font"
              name="mono_font"
              selected={@settings.mono_font}
              families={font_options(@fonts, :mono)}
            />
            <%!-- Glyphs a mono face is actually judged on: zero, capital O, one, lowercase l,
                  capital I, and the punctuation that carries code. --%>
            <p
              phx-no-curly-interpolation
              class="mt-2 border border-zinc-800 bg-[#111] px-2 py-1.5 font-mono text-2xs text-zinc-400"
            >
              def hello(0O1lI), do: {:ok, "eva"} # #-> 12345
            </p>
          </div>

          <div>
            <label for="settings-font-scale" class="text-3xs uppercase tracking-wider text-zinc-600">
              Font size
            </label>
            <select
              id="settings-font-scale"
              name="font_scale"
              class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
            >
              <option
                :for={scale <- EvaWeb.Settings.scales()}
                value={scale}
                selected={scale == @settings.font_scale}
                class="bg-zinc-900"
              >
                {scale}%{if scale == 100, do: " (default)"}
              </option>
            </select>
          </div>

          <div class="flex items-center justify-between border-t border-zinc-800 pt-3">
            <p class="text-3xs text-zinc-600">
              {settings_hint(@fonts)}
            </p>
            <button
              type="button"
              phx-click="rescan_fonts"
              class="shrink-0 border border-zinc-700 px-2 py-1 text-3xs text-zinc-400 transition-colors hover:border-zinc-500 hover:text-zinc-200"
            >
              Rescan
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :selected, :string, default: nil
  attr :families, :list, required: true

  defp font_select(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
    >
      <option value="" selected={is_nil(@selected)} class="bg-zinc-900">System default</option>
      <option
        :for={family <- @families}
        value={family}
        selected={family == @selected}
        class="bg-zinc-900"
      >
        {family}
      </option>
    </select>
    """
  end

  # A family the user picked before uninstalling it would otherwise vanish from the list while
  # still being the selected value, leaving the control showing the wrong thing.
  defp font_options(%{ui: ui}, :ui), do: ui
  defp font_options(%{mono: mono}, :mono), do: mono
  defp font_options(_loading, _kind), do: []

  defp settings_hint(:loading), do: "Reading installed fonts…"

  defp settings_hint(%{ui: ui}),
    do: "#{length(ui)} #{ngettext_family(length(ui))} installed"

  defp ngettext_family(1), do: "family"
  defp ngettext_family(_count), do: "families"

  @doc """
  Header control showing how many MCP servers are connected, and opening the panel.

  Hidden entirely when the project configures no servers — an "MCP 0/0" chip is noise for the
  sessions that never touch MCP at all.
  """
  attr :mcp, :map, required: true
  attr :open, :boolean, default: false

  def mcp_indicator(assigns) do
    {connected, total} = MCP.connected(assigns.mcp)

    assigns =
      assigns
      |> assign(connected: connected, total: total)
      |> assign(:unhealthy, MCP.unhealthy(assigns.mcp))

    ~H"""
    <button
      :if={MCP.any?(@mcp) or @mcp.diagnostics != []}
      id="mcp-toggle"
      type="button"
      phx-click="toggle_mcp"
      title="MCP servers"
      aria-expanded={to_string(@open)}
      class={[
        "flex shrink-0 items-center gap-1.5 border px-2 py-0.5 text-3xs transition-colors",
        if(@open,
          do: "border-zinc-500 text-zinc-200",
          else: "border-zinc-800 text-zinc-500 hover:border-zinc-600 hover:text-zinc-300"
        )
      ]}
    >
      <span class={[
        "size-1.5 shrink-0 rounded-full",
        cond do
          @unhealthy != [] -> "bg-red-500"
          @total == 0 -> "bg-zinc-600"
          @connected == @total -> "bg-emerald-500"
          true -> "animate-pulse bg-amber-500"
        end
      ]} />
      <span class="font-medium tracking-wide">MCP</span>
      <span class="tabular-nums">{@connected}/{@total}</span>
    </button>
    """
  end

  @doc """
  Slide-over listing every configured MCP server and what it is currently offering.

  Rendered as a sibling of the transcript rather than a modal: the user opens it to read a failure
  while the agent keeps working, so the conversation stays visible next to it. Below `xl` there
  isn't room for both once the session sidebar has taken its share, so it overlays instead of
  squeezing the transcript into a column too narrow to read.
  """
  attr :mcp, :map, required: true
  attr :open, :boolean, default: false

  def mcp_panel(assigns) do
    ~H"""
    <div
      :if={@open}
      id="mcp-panel"
      class="absolute inset-y-0 right-0 z-40 flex w-96 max-w-full shrink-0 flex-col border-l border-zinc-800 bg-[#0a0a0a] shadow-2xl xl:static xl:z-auto xl:shadow-none"
      phx-window-keydown="close_mcp"
      phx-key="escape"
    >
      <div class="flex h-12 shrink-0 items-center justify-between border-b border-zinc-800 px-4">
        <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
          MCP servers
        </span>
        <button
          type="button"
          phx-click="close_mcp"
          title="Close"
          aria-label="Close MCP panel"
          class="flex size-6 items-center justify-center text-zinc-600 transition-colors hover:text-zinc-200"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <div class="flex-1 overflow-y-auto">
        <p
          :for={diagnostic <- @mcp.diagnostics}
          class="border-b border-zinc-800 bg-amber-950/20 px-4 py-2 text-2xs text-amber-500/90"
        >
          {diagnostic}
        </p>

        <p :if={@mcp.servers == []} class="px-4 py-6 text-xs leading-relaxed text-zinc-600">
          No MCP servers configured. Add them to <code class="text-zinc-500">~/.eva/mcp.json</code>
          or <code class="text-zinc-500">.eva/mcp.json</code>
          in the project.
        </p>

        <.mcp_server :for={server <- @mcp.servers} server={server} />
      </div>
    </div>
    """
  end

  attr :server, :map, required: true

  defp mcp_server(assigns) do
    ~H"""
    <section
      id={"mcp-server-#{MCP.scope_label(@server.scope)}-#{@server.name}"}
      class="border-b border-zinc-800 px-4 py-3"
    >
      <div class="flex items-center gap-2">
        <.mcp_switch server={@server} />
        <span class={[
          "min-w-0 flex-1 truncate text-sm",
          if(@server.enabled?, do: "text-zinc-200", else: "text-zinc-500")
        ]}>
          {@server.name}
        </span>
        <span class="shrink-0 border border-zinc-800 px-1.5 py-0.5 text-4xs uppercase tracking-wider text-zinc-600">
          {@server.transport}
        </span>
        <span class="shrink-0 border border-zinc-800 px-1.5 py-0.5 text-4xs uppercase tracking-wider text-zinc-600">
          {MCP.scope_label(@server.scope)}
        </span>
      </div>

      <p class="mt-1 truncate text-2xs text-zinc-600" title={@server.target}>{@server.target}</p>

      <div class="mt-1 flex items-center gap-2 text-3xs text-zinc-600">
        <span class={mcp_status_text_class(@server.status)}>{mcp_status_label(@server.status)}</span>
        <span :if={@server.server_version}>v{@server.server_version}</span>
        <span :if={@server.protocol_version}>spec {@server.protocol_version}</span>
      </div>

      <%!-- A session toggle lives in this session's transcript, so the same server can be on for
            one conversation and off for the next. Saying so — and offering the one action that
            makes it stick — is what keeps that from being a surprise. --%>
      <div
        :if={@server.overridden?}
        class="mt-2 flex items-center justify-between gap-2 border border-zinc-800 bg-zinc-900/40 px-2 py-1"
      >
        <span class="min-w-0 text-3xs text-zinc-500">
          This session only — {if @server.config_enabled,
            do: "config says on",
            else: "config says off"}
        </span>
        <button
          type="button"
          id={"mcp-persist-#{@server.name}"}
          phx-click="mcp_persist"
          phx-value-name={@server.name}
          phx-value-enabled={to_string(@server.enabled?)}
          title="Write this to mcp.json"
          class="shrink-0 border border-zinc-700 px-1.5 py-0.5 text-3xs text-zinc-400 transition-colors hover:border-zinc-500 hover:text-zinc-200"
        >
          Save to config
        </button>
      </div>

      <p
        :if={@server.error}
        class="mt-2 break-words border border-red-900/60 bg-red-950/30 px-2 py-1 text-2xs text-red-300"
      >
        {@server.error}
      </p>

      <p
        :if={@server.login_command}
        class="mt-2 break-all border border-amber-900/60 bg-amber-950/20 px-2 py-1 text-2xs text-amber-300"
      >
        Run <code>{@server.login_command}</code>
      </p>

      <details :if={@server.tools != []} class="mt-2 group">
        <summary class="cursor-pointer text-2xs text-zinc-500 hover:text-zinc-300">
          {length(@server.tools)} {ngettext_tool(length(@server.tools))}
        </summary>
        <ul class="mt-1 space-y-1 border-l border-zinc-800 pl-2">
          <li :for={tool <- @server.tools}>
            <p class="truncate font-mono text-2xs text-zinc-400">{tool.name}</p>
            <p :if={tool[:description]} class="line-clamp-2 text-3xs leading-relaxed text-zinc-600">
              {tool.description}
            </p>
          </li>
        </ul>
      </details>

      <p
        :if={@server.tools == [] and @server.status == :connected}
        class="mt-2 text-2xs text-zinc-600"
      >
        No tools exposed.
      </p>
    </section>
    """
  end

  # On/off for one server, scoped to this session. The status dot doubles as the switch rather than
  # sitting next to one: it already said whether the server was running, and two controls for one
  # fact is how they end up disagreeing.
  attr :server, :map, required: true

  defp mcp_switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      id={"mcp-switch-#{@server.name}"}
      aria-checked={to_string(@server.enabled?)}
      aria-label={"#{if @server.enabled?, do: "Disable", else: "Enable"} #{@server.name}"}
      phx-click="mcp_set_enabled"
      phx-value-name={@server.name}
      phx-value-enabled={to_string(not @server.enabled?)}
      title={if @server.enabled?, do: "Switch off for this session", else: "Switch on"}
      class={[
        "flex h-4 w-8 shrink-0 items-center gap-px border p-px transition-colors",
        if(@server.enabled?,
          do: "border-zinc-600 bg-zinc-800/80",
          else: "border-zinc-800 bg-transparent hover:border-zinc-600"
        )
      ]}
    >
      <%!-- Two cells rather than a sliding knob: the filled one is the side the switch is on, which
            reads at this size where a 2px travel distance does not. --%>
      <span class={[
        "h-full flex-1 transition-colors",
        if(@server.enabled?, do: "bg-transparent", else: "bg-zinc-800")
      ]} />
      <span class={[
        "h-full flex-1 transition-colors",
        if(@server.enabled?, do: mcp_status_class(@server.status), else: "bg-transparent")
      ]} />
    </button>
    """
  end

  defp mcp_status_label(:connected), do: "connected"
  defp mcp_status_label(:connecting), do: "connecting…"
  defp mcp_status_label(:needs_auth), do: "needs login"
  defp mcp_status_label(:disabled), do: "off"
  defp mcp_status_label(:failed), do: "failed"

  defp mcp_status_class(:connected), do: "bg-emerald-500"
  defp mcp_status_class(:connecting), do: "animate-pulse bg-amber-500"
  defp mcp_status_class(:needs_auth), do: "bg-amber-500"
  defp mcp_status_class(:disabled), do: "bg-zinc-700"
  defp mcp_status_class(:failed), do: "bg-red-500"

  defp mcp_status_text_class(:failed), do: "text-red-400"
  defp mcp_status_text_class(:needs_auth), do: "text-amber-400"
  defp mcp_status_text_class(:connected), do: "text-emerald-500"
  defp mcp_status_text_class(_status), do: "text-zinc-500"

  defp ngettext_tool(1), do: "tool"
  defp ngettext_tool(_count), do: "tools"

  defp ngettext_fork(1), do: "fork"
  defp ngettext_fork(_count), do: "forks"

  defp said_something?(%{blocks: blocks}), do: Enum.any?(blocks, &match?({:text, _text}, &1))

  # A command runs whether or not Eva is mid-turn is up to Eva, which refuses while the agent
  # works — so the placeholder says so rather than letting the user type into a refusal.
  defp composer_placeholder(:prompt, true), do: "Queue a follow-up…"
  defp composer_placeholder(:prompt, false), do: "Send a message…"

  defp composer_placeholder(_command_mode, true),
    do: "Eva is working — commands run when it stops"

  defp composer_placeholder(:command, false), do: "Run a shell command…"
  defp composer_placeholder(:private_command, false), do: "Run a command, keep it off the model…"

  @doc """
  The fork glyph, drawn as GitHub draws it.

  Not a heroicon: the set has nothing that reads as a branch, and this is the shape anyone who has
  used a repository already knows means "fork".
  """
  attr :class, :string, default: "size-4"

  def fork_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" class={@class}>
      <path d="M5 5.372v.878c0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75v-.878a2.25 2.25 0 1 1 1.5 0v.878a2.25 2.25 0 0 1-2.25 2.25h-1.5v2.128a2.251 2.251 0 1 1-1.5 0V8.5h-1.5A2.25 2.25 0 0 1 3.5 6.25v-.878a2.25 2.25 0 1 1 1.5 0ZM5 3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Zm6.75.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm-3 8.75a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Z" />
    </svg>
    """
  end

  @doc "One transcript row. Dispatches on the item kind produced by `Transcript`."
  attr :item, :map, required: true

  def message(%{item: %{kind: :user}} = assigns) do
    ~H"""
    <div class="group flex flex-col items-end gap-1 px-4 py-2">
      <%!-- phx-no-format keeps the text flush against the tags. Without it the formatter re-indents
           and whitespace-pre-wrap renders the template's own newlines as blank lines inside the
           bubble, plus a left offset from the indentation. --%>
      <div
        id={"#{@item.id}-body"}
        phx-no-format
        class="max-w-[85%] whitespace-pre-wrap break-words border border-zinc-700 bg-[#1c1c1c] px-3 py-2 text-sm text-zinc-100"
      >{@item.text}</div>

      <%!-- Forks first, then the controls, then the time: the timestamp is the one thing here that
            is always present, so it anchors the right edge under the corner of the bubble while
            everything else grows leftwards from it. --%>
      <div class="flex max-w-[85%] flex-wrap items-center justify-end gap-1.5">
        <span :if={@item.forks != []} class="text-3xs uppercase tracking-wider text-zinc-600">
          {length(@item.forks)} {ngettext_fork(length(@item.forks))}
        </span>
        <.link
          :for={fork <- @item.forks}
          patch={~p"/sessions/#{fork.session_id}"}
          title={"Open #{fork.title}"}
          class="flex max-w-[16rem] items-center gap-1 border border-zinc-800 px-1.5 py-0.5 text-2xs text-zinc-500 transition-colors hover:border-zinc-600 hover:text-zinc-200"
        >
          <.fork_icon class="size-3 shrink-0 text-zinc-600" />
          <span class="truncate">{fork.title}</span>
        </.link>
        <.copy_button item={@item} />
        <%!-- Only offered once the message has an entry to fork at, which is a beat after it is
              sent. --%>
        <button
          :if={@item.entry_id}
          type="button"
          phx-click="fork"
          phx-value-entry={@item.entry_id}
          title="Fork the conversation from this message"
          class="shrink-0 text-zinc-700 opacity-0 transition-all hover:text-zinc-300 focus:opacity-100 group-hover:opacity-100"
        >
          <.fork_icon class="size-3.5" />
        </button>
        <.message_time at={@item.at} />
      </div>
    </div>
    """
  end

  def message(%{item: %{kind: :assistant}} = assigns) do
    ~H"""
    <div class="group px-4 py-2">
      <div id={"#{@item.id}-body"} class="max-w-[85%] space-y-2">
        <%= for {block, index} <- Enum.with_index(@item.blocks) do %>
          <%= case block do %>
            <% {:thinking, thinking} -> %>
              <details
                id={"#{@item.id}-thinking-#{index}"}
                phx-hook="KeepOpen"
                class="border-l-2 border-zinc-800 pl-3"
              >
                <summary class="cursor-pointer text-xs italic text-zinc-600 hover:text-zinc-400">
                  Thinking
                </summary>
                <div
                  phx-no-format
                  class="mt-1 whitespace-pre-wrap break-words text-xs italic text-zinc-500"
                >{thinking}</div>
              </details>
            <% {:text, text} -> %>
              <%!-- data-copy-part is what the copy button collects: the prose, without the
                    thinking blocks wrapped around it. --%>
              <div data-copy-part class="md break-words text-sm text-zinc-200">{markdown(text)}</div>
          <% end %>
        <% end %>

        <div :if={@item.blocks == [] and is_nil(@item.error)} class="flex items-center gap-1 py-1">
          <span class="size-1.5 animate-pulse rounded-full bg-zinc-600" />
          <span class="size-1.5 animate-pulse rounded-full bg-zinc-600" style="animation-delay:.2s" />
          <span class="size-1.5 animate-pulse rounded-full bg-zinc-600" style="animation-delay:.4s" />
        </div>

        <p
          :if={@item.error}
          class="border border-red-900 bg-red-950/40 px-3 py-2 text-sm text-red-300"
        >
          {@item.error}
        </p>
      </div>

      <%!-- A row that has only thought so far has nothing to copy and isn't finished being said. --%>
      <div :if={said_something?(@item)} class="mt-1 flex max-w-[85%] items-center gap-1.5">
        <.message_time at={@item.at} />
        <.copy_button item={@item} />
      </div>
    </div>
    """
  end

  def message(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <div class="px-4 py-1">
      <%!-- A command you ran yourself opens with its output showing: you ran it to read it. The
            model's own calls stay shut, or a turn with a dozen of them buries the reply. --%>
      <details
        id={"#{@item.id}-output"}
        open={@item.origin == :user}
        phx-hook="KeepOpen"
        class="max-w-[85%] border border-zinc-800 bg-[#111] text-xs"
      >
        <summary class="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-zinc-400 hover:text-zinc-200">
          <.tool_status status={@item.status} />
          <span
            :if={@item.server}
            class="shrink-0 border border-zinc-700 px-1 text-4xs uppercase tracking-wider text-zinc-500"
            title={"MCP server: #{@item.server}"}
          >
            {@item.server}
          </span>
          <%!-- Without this a command you ran and one the model ran are the same row. --%>
          <span
            :if={@item.origin == :user}
            class="shrink-0 border border-emerald-900 px-1 text-4xs uppercase tracking-wider text-emerald-600"
            title="You ran this"
          >
            you
          </span>
          <span
            :if={@item.private?}
            class="shrink-0 border border-amber-900/70 px-1 text-4xs uppercase tracking-wider text-amber-600/90"
            title="Kept out of the model's context"
          >
            private
          </span>
          <span class="font-medium text-zinc-300">{@item.name}</span>
          <span class="min-w-0 truncate text-zinc-600">{Transcript.args_summary(@item.args)}</span>
        </summary>
        <%!-- Progress replaces the (still empty) output while the call is in flight. --%>
        <p
          :if={@item.progress && @item.status == :running}
          class="border-t border-zinc-800 px-3 py-1.5 text-2xs italic text-zinc-500"
        >
          {@item.progress}
        </p>
        <.tool_body item={@item} />
      </details>
    </div>
    """
  end

  def message(%{item: %{kind: :note}} = assigns) do
    ~H"""
    <div class="px-4 py-2 text-center text-xs italic text-zinc-600">{@item.text}</div>
    """
  end

  @doc """
  When a row was written, in the clock of whoever is reading it.

  Eva's timestamps are unix seconds and the app runs on the same machine as the person using it, so
  the OS timezone is the right one — and it needs no timezone database to get there.
  """
  attr :at, :float, default: nil

  def message_time(assigns) do
    ~H"""
    <time :if={@at} datetime={iso_time(@at)} title={long_time(@at)} class="text-3xs text-zinc-700">
      {short_time(@at)}
    </time>
    """
  end

  @doc """
  Copies a message.

  The text is read back out of the DOM rather than sent down with the button: an assistant message
  is already on the page in full, and repeating it in an attribute would double what every streamed
  delta puts on the wire.
  """
  attr :item, :map, required: true

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@item.id}-copy"}
      phx-hook="Copy"
      data-copy-from={"#{@item.id}-body"}
      title="Copy message"
      class="flex size-3.5 shrink-0 items-center justify-center text-zinc-700 opacity-0 transition-all hover:text-zinc-300 focus:opacity-100 group-hover:opacity-100"
    >
      <%!-- Both states are laid out identically and the box is sized on the button itself, so
            swapping one for the other can't nudge the row it sits in. --%>
      <span data-icon="idle" class="flex">
        <.icon name="hero-square-2-stack-mini" class="size-3.5" />
      </span>
      <span data-icon="done" class="hidden">
        <.icon name="hero-check-mini" class="size-3.5 text-emerald-500" />
      </span>
    </button>
    """
  end

  attr :item, :map, required: true

  defp tool_body(assigns) do
    assigns =
      assigns
      |> assign(
        :has_patch,
        assigns.item.name == "edit" && is_binary(assigns.item.patch) && assigns.item.patch != ""
      )
      |> assign(:has_text, is_binary(assigns.item.text) && assigns.item.text != "")

    ~H"""
    <%= if @has_patch do %>
      <div class="border-t border-zinc-800">
        <div class="flex items-center justify-between px-3 py-1.5">
          <span class="text-3xs font-medium uppercase tracking-wider text-zinc-600">
            Patch
          </span>
        </div>
        <pre
          phx-no-curly-interpolation
          class="max-h-64 overflow-auto px-3 pb-2 text-2xs leading-relaxed"
        ><code><%= for line <- String.split(@item.patch, "\n") do %><span class={diff_line_class(line)}><%= line %><%= "\n" %></span><% end %></code></pre>
      </div>
    <% end %>
    <%= if @has_text do %>
      <pre
        phx-no-curly-interpolation
        class={[
          "max-h-64 overflow-auto px-3 py-2 text-2xs leading-relaxed text-zinc-400",
          !@has_patch && "border-t border-zinc-800"
        ]}
      ><%= @item.text %></pre>
    <% end %>
    """
  end

  defp diff_line_class(<<"+", _rest::binary>>), do: "block bg-emerald-950/40 text-emerald-400"
  defp diff_line_class(<<"-", _rest::binary>>), do: "block bg-red-950/40 text-red-400"
  defp diff_line_class(<<"@", _rest::binary>>), do: "block text-cyan-500"
  defp diff_line_class(_), do: "block text-zinc-500"

  attr :status, :atom, default: nil

  defp tool_status(%{status: :running} = assigns) do
    ~H"""
    <span class="size-1.5 shrink-0 animate-pulse rounded-full bg-amber-500" title="Running" />
    """
  end

  defp tool_status(%{status: :error} = assigns) do
    ~H"""
    <.icon name="hero-x-mark-mini" class="size-3.5 shrink-0 text-red-400" />
    """
  end

  defp tool_status(assigns) do
    ~H"""
    <.icon name="hero-check-mini" class="size-3.5 shrink-0 text-emerald-500" />
    """
  end

  @modes [
    prompt: %{label: "prompt", hint: "! for a command"},
    command: %{label: "command", hint: "! again to keep it private · esc to leave"},
    private_command: %{label: "private command", hint: "not sent to the model · esc to leave"}
  ]

  @doc "The mode the composer is in, and the way out of it. Clicking it cycles."
  attr :mode, :atom, required: true

  def composer_mode(assigns) do
    assigns = assign(assigns, mode_info: Keyword.fetch!(@modes, assigns.mode))

    ~H"""
    <div class="mx-auto mb-2 flex max-w-3xl items-center gap-2">
      <button
        type="button"
        phx-click="cycle_mode"
        title="Switch mode"
        class={[
          "flex items-center gap-1.5 border px-2 py-0.5 text-3xs uppercase tracking-wider transition-colors",
          mode_class(@mode)
        ]}
      >
        <span :if={@mode != :prompt} class="font-mono normal-case">!</span>
        {@mode_info.label}
      </button>
      <span class="truncate text-3xs text-zinc-700">{@mode_info.hint}</span>
    </div>
    """
  end

  defp mode_class(:prompt), do: "border-zinc-800 text-zinc-600 hover:border-zinc-600"
  defp mode_class(:command), do: "border-emerald-900 text-emerald-600 hover:border-emerald-700"

  defp mode_class(:private_command),
    do: "border-amber-900/70 text-amber-600/90 hover:border-amber-700"

  @doc "Message input. Enter sends, shift+Enter inserts a newline (see the ChatInput hook)."
  attr :running, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :mode, :atom, default: :prompt
  attr :command_running, :boolean, default: false

  def composer(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-zinc-800 bg-[#0c0c0c] p-4">
      <.composer_mode mode={@mode} />
      <form id="composer" phx-submit="send" class="mx-auto flex max-w-3xl items-end gap-3">
        <%!-- The mode rides on the element the hook is bound to: it decides there whether a
              leading `!` is text or a mode switch, without a round trip to ask. --%>
        <textarea
          id="chat-input"
          name="text"
          rows="1"
          phx-hook="ChatInput"
          data-mode={@mode}
          disabled={@disabled}
          placeholder={composer_placeholder(@mode, @running)}
          class={[
            "min-h-[var(--composer-row)] flex-1 resize-none border bg-transparent px-3 py-2 text-sm text-white outline-none placeholder:text-zinc-600 disabled:opacity-50",
            @mode == :prompt && "border-zinc-700 focus:border-zinc-500",
            @mode == :command && "border-emerald-900 font-mono focus:border-emerald-700",
            @mode == :private_command && "border-amber-900/70 font-mono focus:border-amber-700"
          ]}
        />
        <button
          :if={@command_running}
          id="cancel-command-button"
          type="button"
          phx-click="cancel_bash"
          title="Stop the command"
          class="flex h-[var(--composer-row)] w-9 shrink-0 items-center justify-center border border-zinc-700 text-zinc-300 transition-colors hover:border-red-700 hover:text-red-400"
        >
          <.icon name="hero-stop-mini" class="size-4" />
        </button>
        <button
          :if={@running}
          id="cancel-button"
          type="button"
          phx-click="cancel"
          title="Stop"
          class="flex h-[var(--composer-row)] w-9 shrink-0 items-center justify-center border border-zinc-700 text-zinc-300 transition-colors hover:border-red-700 hover:text-red-400"
        >
          <.icon name="hero-stop-mini" class="size-4" />
        </button>
        <button
          :if={not @running and not @command_running}
          id="send-button"
          type="submit"
          disabled={@disabled}
          class={[
            "flex h-[var(--composer-row)] w-9 shrink-0 items-center justify-center text-white transition-colors disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:opacity-50",
            @mode == :prompt && "bg-[#116a34b5] hover:bg-[#116a34]",
            @mode == :command && "bg-emerald-900/70 hover:bg-emerald-800",
            @mode == :private_command && "bg-amber-900/70 hover:bg-amber-800"
          ]}
        >
          <.icon
            name={if @mode == :prompt, do: "hero-arrow-right-mini", else: "hero-play-mini"}
            class="size-4"
          />
        </button>
      </form>
    </div>
    """
  end

  @doc """
  Renders assistant markdown as sanitized HTML.

  The model's output is untrusted and must never reach `raw/1` unsanitized — the `read` tool alone
  can drop arbitrary repo file contents into a message, so a file containing `<img onerror=...>`
  would otherwise become live markup. `hardbreaks` keeps single newlines visible, which is what
  chat readers expect and plain CommonMark would swallow.
  """
  @spec markdown(String.t()) :: Phoenix.HTML.safe() | String.t()
  def markdown(text) do
    case MDEx.to_html(text,
           extension: [table: true, strikethrough: true, tasklist: true, autolink: true],
           render: [hardbreaks: true],
           syntax_highlight: [engine: :syntect, opts: [theme: @code_theme]],
           sanitize:
             MDEx.Document.default_sanitize_options()
             |> Keyword.put(:set_tag_attribute_values, %{"a" => %{"target" => "_blank"}})
         ) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      # Show the raw text rather than losing the message; HEEx escapes it.
      {:error, _reason} -> text
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Clock time for a transcript row: bare on the day it happened, dated before that.

  A conversation is read as a sequence of turns, so the useful part is the time of day; the date
  only earns its space once the reader has to place a row on another day.
  """
  @spec short_time(number()) :: String.t()
  def short_time(at) do
    {{year, month, day}, {hour, minute, _second}} = local(at)
    {today, _now} = :calendar.local_time()
    clock = "#{hour12(hour)}:#{pad(minute)} #{meridiem(hour)}"

    if {year, month, day} == today do
      clock
    else
      "#{Enum.at(@months, month - 1)} #{day}, #{clock}"
    end
  end

  @doc "The whole of a row's timestamp, for the tooltip the short form hides it behind."
  @spec long_time(number()) :: String.t()
  def long_time(at) do
    {{year, month, day}, {hour, minute, second}} = local(at)
    clock = "#{hour12(hour)}:#{pad(minute)}:#{pad(second)} #{meridiem(hour)}"

    "#{day} #{Enum.at(@months, month - 1)} #{year}, #{clock}"
  end

  @doc "A row's timestamp as UTC ISO 8601, for the `datetime` attribute machines read."
  @spec iso_time(number()) :: String.t()
  def iso_time(at) do
    at |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  # The OS timezone, which on a tool that runs beside the person using it is the right one — and
  # unlike `DateTime.shift_zone/2` it needs no timezone database to be configured.
  defp local(at), do: :calendar.system_time_to_local_time(trunc(at * 1000), :millisecond)

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # Midnight and noon are the 12s, not the 0s.
  defp hour12(0), do: 12
  defp hour12(hour) when hour > 12, do: hour - 12
  defp hour12(hour), do: hour

  defp meridiem(hour) when hour < 12, do: "am"
  defp meridiem(_hour), do: "pm"

  @doc "Coarse relative time from Eva's float unix-seconds timestamps."
  def relative_time(nil), do: ""

  def relative_time(timestamp) do
    diff = System.system_time(:second) - trunc(timestamp)

    cond do
      diff < 60 -> "now"
      diff < 3_600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3_600)}h"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d"
      true -> "#{div(diff, 2_592_000)}mo"
    end
  end
end
