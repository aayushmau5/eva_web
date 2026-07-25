defmodule EvaWebWeb.Layouts do
  use EvaWebWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :sidebar
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen bg-[#0c0c0c] text-zinc-200">
      <aside
        :if={@sidebar != []}
        id="sidebar"
        class="hidden md:flex md:w-72 shrink-0 flex-col border-r border-zinc-800 bg-[#0a0a0a]"
      >
        {render_slot(@sidebar)}
      </aside>
      <div class="flex flex-col flex-1 min-w-0">
        {render_slot(@inner_block)}
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the app's flash messages. Kept here because Phoenix v1.8 forbids calling
  `<.flash_group>` from outside the Layouts module.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="fixed top-4 right-4 z-50 flex w-80 flex-col gap-2">
      <.notice kind={:info} flash={@flash} />
      <.notice kind={:error} flash={@flash} />
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error]

  defp notice(assigns) do
    ~H"""
    <div
      :if={message = Phoenix.Flash.get(@flash, @kind)}
      id={"flash-#{@kind}"}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      class={[
        "cursor-pointer border px-3 py-2 text-sm shadow-lg transition-opacity hover:opacity-80",
        @kind == :info && "border-zinc-700 bg-zinc-900 text-zinc-200",
        @kind == :error && "border-red-900 bg-red-950 text-red-200"
      ]}
    >
      {message}
    </div>
    """
  end
end
