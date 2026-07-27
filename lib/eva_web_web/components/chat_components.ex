defmodule EvaWebWeb.ChatComponents do
  @moduledoc """
  Presentational pieces of the chat UI: the session sidebar, transcript rows, and the composer.
  """
  use EvaWebWeb, :html

  alias EvaWeb.Sessions.Transcript

  # Syntect ships its own themes (from the Rust two-face crate) and emits inline styles, so the
  # colours come from MDEx rather than being hand-rolled here. Coldark-Dark's #111b27 background is
  # the closest of the bundled dark themes to the code blocks elsewhere in the UI.
  # Requires `config :mdex_native, syntax_highlighter: :syntect`, read at NIF compile time.
  @code_theme "Coldark-Dark"

  @doc "Session list, grouped by project directory."
  attr :groups, :list, required: true
  attr :running_ids, :any, required: true
  attr :active_id, :string, default: nil
  attr :providers, :list, default: []
  attr :new_session, :map, default: nil

  def sidebar(assigns) do
    ~H"""
    <div class="flex h-12 shrink-0 items-center justify-between border-b border-zinc-800 px-4">
      <span class="text-sm font-semibold tracking-wide text-zinc-300">Eva</span>
      <button
        id="new-session"
        type="button"
        phx-click={if @new_session, do: "cancel_new_session", else: "start_new_session"}
        title="New session"
        class="flex size-7 items-center justify-center border border-zinc-700 text-zinc-400 transition-colors hover:border-zinc-500 hover:text-zinc-100"
      >
        <.icon name={if @new_session, do: "hero-x-mark-mini", else: "hero-plus-mini"} class="size-4" />
      </button>
    </div>

    <%!-- Sessions belong to a project directory, and the sidebar spans every project, so a new
         one needs somewhere to live rather than always inheriting the current view's. Provider and
         model are fixed at creation too: they are written onto the index entry, and Eva reads the
         model once when the session starts. --%>
    <form
      :if={@new_session}
      id="new-session-form"
      phx-change="new_session_change"
      phx-submit="new_session"
      class="space-y-3 border-b border-zinc-800 px-4 py-3"
    >
      <div>
        <label for="new-session-cwd" class="text-[10px] uppercase tracking-wider text-zinc-600">
          Working directory
        </label>
        <input
          id="new-session-cwd"
          type="text"
          name="cwd"
          value={@new_session.cwd}
          autocomplete="off"
          spellcheck="false"
          class="mt-1 w-full border border-zinc-700 bg-transparent px-2 py-1 text-xs text-zinc-200 outline-none focus:border-zinc-500"
        />
      </div>

      <div>
        <label for="new-session-provider" class="text-[10px] uppercase tracking-wider text-zinc-600">
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
        <label for="new-session-model" class="text-[10px] uppercase tracking-wider text-zinc-600">
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
        <h3
          class="truncate px-4 py-1 text-[10px] font-semibold uppercase tracking-wider text-zinc-600"
          title={group.cwd}
        >
          {group.label}
        </h3>
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
            <span class="shrink-0 text-[10px] text-zinc-600">
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
    <p :if={@new_session.models == :loading} class="mt-1 text-[10px] text-zinc-600">
      Loading models…
    </p>
    <p
      :if={match?({:error, _reason}, @new_session.models)}
      id="new-session-model-error"
      class="mt-1 text-[10px] text-amber-600/90"
    >
      {elem(@new_session.models, 1)}
    </p>
    <p :if={@new_session.models == {:ok, []}} class="mt-1 text-[10px] text-zinc-600">
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

  @doc "One transcript row. Dispatches on the item kind produced by `Transcript`."
  attr :item, :map, required: true

  def message(%{item: %{kind: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end px-4 py-2">
      <%!-- phx-no-format keeps the text flush against the tags. Without it the formatter re-indents
           and whitespace-pre-wrap renders the template's own newlines as blank lines inside the
           bubble, plus a left offset from the indentation. --%>
      <div
        phx-no-format
        class="max-w-[85%] whitespace-pre-wrap break-words border border-zinc-700 bg-[#1c1c1c] px-3 py-2 text-sm text-zinc-100"
      >{@item.text}</div>
    </div>
    """
  end

  def message(%{item: %{kind: :assistant}} = assigns) do
    ~H"""
    <div class="px-4 py-2">
      <div class="max-w-[85%] space-y-2">
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
              <div class="md break-words text-sm text-zinc-200">{markdown(text)}</div>
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
    </div>
    """
  end

  def message(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <div class="px-4 py-1">
      <details
        id={"#{@item.id}-output"}
        phx-hook="KeepOpen"
        class="max-w-[85%] border border-zinc-800 bg-[#111] text-xs"
      >
        <summary class="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-zinc-400 hover:text-zinc-200">
          <.tool_status status={@item.status} />
          <span class="font-medium text-zinc-300">{@item.name}</span>
          <span class="truncate text-zinc-600">{Transcript.args_summary(@item.args)}</span>
        </summary>
        <pre
          :if={@item.text != ""}
          phx-no-curly-interpolation
          class="max-h-64 overflow-auto border-t border-zinc-800 px-3 py-2 text-[11px] leading-relaxed text-zinc-400"
        ><%= @item.text %></pre>
      </details>
    </div>
    """
  end

  def message(%{item: %{kind: :note}} = assigns) do
    ~H"""
    <div class="px-4 py-2 text-center text-xs italic text-zinc-600">{@item.text}</div>
    """
  end

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

  @doc "Message input. Enter sends, shift+Enter inserts a newline (see the ChatInput hook)."
  attr :running, :boolean, required: true
  attr :disabled, :boolean, default: false

  def composer(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-zinc-800 bg-[#0c0c0c] p-4">
      <form id="composer" phx-submit="send" class="mx-auto flex max-w-3xl items-end gap-3">
        <textarea
          id="chat-input"
          name="text"
          rows="1"
          phx-hook="ChatInput"
          disabled={@disabled}
          placeholder={if @running, do: "Queue a follow-up…", else: "Send a message…"}
          class="flex-1 resize-none border border-zinc-700 bg-transparent px-3 py-2 text-sm text-white outline-none placeholder:text-zinc-600 focus:border-zinc-500 disabled:opacity-50"
        />
        <button
          :if={@running}
          id="cancel-button"
          type="button"
          phx-click="cancel"
          title="Stop"
          class="flex size-9 shrink-0 items-center justify-center border border-zinc-700 text-zinc-300 transition-colors hover:border-red-700 hover:text-red-400"
        >
          <.icon name="hero-stop-mini" class="size-4" />
        </button>
        <button
          :if={not @running}
          id="send-button"
          type="submit"
          disabled={@disabled}
          class="flex size-9 shrink-0 items-center justify-center bg-[#116a34b5] text-white transition-colors hover:bg-[#116a34] disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:opacity-50"
        >
          <.icon name="hero-arrow-right-mini" class="size-4" />
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
           sanitize: MDEx.Document.default_sanitize_options()
         ) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      # Show the raw text rather than losing the message; HEEx escapes it.
      {:error, _reason} -> text
    end
  end

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
