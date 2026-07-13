defmodule EvaWebWeb.Layouts do
  use EvaWebWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-[#0c0c0c]">
      <header class="flex items-center h-12 px-4 bg-[#0c0c0c] border-b border-zinc-800 shrink-0">
        <span class="text-sm font-semibold tracking-wide text-zinc-300">Eva</span>
      </header>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
