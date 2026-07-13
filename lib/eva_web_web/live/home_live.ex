defmodule EvaWebWeb.HomeLive do
  use EvaWebWeb, :live_view

  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Agent.Events

  @impl true
  def mount(_params, _session, socket) do
    session_pid =
      if connected?(socket) do
        try do
          Eva.setup(self())
        rescue
          e ->
            require Logger
            Logger.error("Failed to start Eva session: #{Exception.message(e)}")
            nil
        end
      end

    {:ok,
     socket
     |> assign(page_title: "Eva")
     |> assign(:session_pid, session_pid)
     |> assign(:input, "")
     |> assign(:msg_id, 0)
     |> assign(:streaming, false)
     |> assign(:current_assistant_id, nil)
     |> assign(:current_content, "")
     |> stream(:messages, [])}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    msg_id = socket.assigns.msg_id + 1
    user_msg = %{id: msg_id, role: "user", content: text}

    socket =
      socket
      |> assign(:msg_id, msg_id)
      |> stream_insert(:messages, user_msg)

    if socket.assigns.session_pid do
      CodingSession.prompt(socket.assigns.session_pid, text)
    end

    {:noreply, assign(socket, :input, "")}
  end

  @impl true
  def handle_event("input", %{"text" => text}, socket) do
    {:noreply, assign(socket, :input, text)}
  end

  @impl true
  def handle_info(%Events.AgentStart{}, socket) do
    {:noreply, assign(socket, :streaming, true)}
  end

  def handle_info(%Events.MessageStart{}, socket) do
    msg_id = socket.assigns.msg_id + 1

    {:noreply,
     socket
     |> assign(:msg_id, msg_id)
     |> assign(:current_assistant_id, msg_id)
     |> assign(:current_content, "")}
  end

  def handle_info(%Events.MessageDelta{delta: delta}, socket) do
    id = socket.assigns.current_assistant_id
    content = socket.assigns.current_content <> delta

    updated = %{id: id, role: "assistant", content: content}

    {:noreply,
     socket
     |> assign(:current_content, content)
     |> stream_insert(:messages, updated)}
  end

  def handle_info(%Events.ThinkingDelta{}, socket) do
    {:noreply, socket}
  end

  def handle_info(%Events.MessageEnd{message: msg}, socket) do
    id = socket.assigns.current_assistant_id

    if socket.assigns.current_content != "" do
      final = %{id: id, role: "assistant", content: msg.content}
      {:noreply, stream_insert(socket, :messages, final)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Events.ToolExecutionStart{tool_call: tc}, socket) do
    msg_id = socket.assigns.msg_id + 1
    tool_msg = %{id: msg_id, role: "tool", content: "Running #{tc.name}..."}

    {:noreply,
     socket
     |> assign(:msg_id, msg_id)
     |> stream_insert(:messages, tool_msg)}
  end

  def handle_info(%Events.ToolExecutionEnd{result: result}, socket) do
    msg_id = socket.assigns.msg_id + 1
    summary =
      if result.ok do
        "✓ #{result.name}"
      else
        "✗ #{result.name}: #{result.error}"
      end

    tool_msg = %{id: msg_id, role: "tool_result", content: summary}

    {:noreply,
     socket
     |> assign(:msg_id, msg_id)
     |> stream_insert(:messages, tool_msg)}
  end

  def handle_info(%Events.Error{message: error_msg}, socket) do
    msg_id = socket.assigns.msg_id + 1
    error = %{id: msg_id, role: "error", content: error_msg}

    {:noreply,
     socket
     |> assign(:msg_id, msg_id)
     |> assign(:streaming, false)
     |> stream_insert(:messages, error)}
  end

  def handle_info(%Events.AgentEnd{}, socket) do
    {:noreply, assign(socket, :streaming, false)}
  end

  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="messages" phx-update="stream" class="flex-1 overflow-y-auto" phx-hook="ScrollToBottom">
        <div
          :for={{dom_id, msg} <- @streams.messages}
          id={dom_id}
          class={["px-4 py-3", msg.role == "user" && "bg-[#2a2a2a]", msg.role == "assistant" && "bg-[#1a1a1a]"]}
        >
          <div class="max-w-3xl mx-auto">
            <span class={["inline-block px-1.5 py-0.5 text-[10px] font-semibold tracking-wide align-middle mr-2", role_badge(msg.role)]}>
              {role_label(msg.role)}
            </span>
            <%= if msg.content == "" do %>
              <span class="inline-flex items-center gap-1 text-zinc-500 align-middle">
                <span class="inline-block w-1.5 h-1.5 bg-zinc-500 rounded-full animate-pulse"></span>
                <span class="inline-block w-1.5 h-1.5 bg-zinc-500 rounded-full animate-pulse" style="animation-delay: 0.2s"></span>
                <span class="inline-block w-1.5 h-1.5 bg-zinc-500 rounded-full animate-pulse" style="animation-delay: 0.4s"></span>
              </span>
            <% else %>
              <span class={["text-sm whitespace-pre-wrap break-words", message_text_color(msg.role)]}>{msg.content}</span>
            <% end %>
          </div>
        </div>
      </div>

      <div class="shrink-0 bg-[#0c0c0c] border-t border-zinc-800 p-4">
        <div class="max-w-3xl mx-auto">
          <form phx-submit="send" class="flex gap-3">
            <div class="flex-1">
              <input
                type="text"
                name="text"
                value={@input}
                phx-change="input"
                phx-debounce="100"
                placeholder="Type a message..."
                class="w-full bg-transparent border border-zinc-700 rounded-none text-sm text-white placeholder-zinc-500 px-3 py-2 outline-none focus:border-zinc-500"
                autocomplete="off"
              />
            </div>
            <button
              type="submit"
              disabled={@input == "" || @streaming}
              class={["shrink-0 w-9 h-9 rounded-none flex items-center justify-center transition-colors", send_button_color(@input, @streaming)]}
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M12 5l7 7-7 7" />
              </svg>
            </button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp role_badge("user"), do: "bg-[#2563ebb5] text-white"
  defp role_badge("assistant"), do: "bg-[#116a34b5] text-white"
  defp role_badge("tool"), do: "bg-[#116a34] text-white"
  defp role_badge("tool_result"), do: "bg-[#116a34] text-white"
  defp role_badge("error"), do: "bg-red-600 text-white"
  defp role_badge(_), do: "bg-zinc-600 text-white"

  defp role_label("user"), do: "USER"
  defp role_label("assistant"), do: "EVA"
  defp role_label("tool"), do: "TOOL"
  defp role_label("tool_result"), do: "✓"
  defp role_label("error"), do: "!"
  defp role_label(_), do: ""

  defp message_text_color("error"), do: "text-red-400"
  defp message_text_color(_), do: "text-zinc-200"

  defp send_button_color(_, true), do: "bg-zinc-600 opacity-50 cursor-not-allowed"
  defp send_button_color("", _), do: "bg-zinc-600 opacity-50 cursor-not-allowed"
  defp send_button_color(_, _), do: "bg-[#116a34b5] text-white"
end
