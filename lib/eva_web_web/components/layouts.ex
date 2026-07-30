defmodule EvaWebWeb.Layouts do
  use EvaWebWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :settings, :map, default: %{ui_font: nil, mono_font: nil, font_scale: 100}
  slot :sidebar
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :font_vars, font_vars(assigns.settings))

    ~H"""
    <%!-- `contents` so this wrapper carries the font settings to the flashes as well as the app
          without putting a box between them and the viewport. --%>
    <div class="contents font-sans" style={@font_vars}>
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
    </div>
    """
  end

  # Overriding Tailwind's own `--font-sans` / `--font-mono` rather than setting `font-family`
  # outright is what makes one declaration reach everything: `font-sans` on this element covers the
  # tree by inheritance, and Tailwind's preflight resolves `code`/`pre` and every `font-mono`
  # utility inside it through the same variables.
  #
  # The chosen family is only ever the *first* entry. Dropping the rest of the stack would leave a
  # font with no Devanagari — or no box-drawing glyphs — with nothing to fall back to.
  @sans_stack ~s(ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji")
  @mono_stack ~s(ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace)

  # The whole type ramp, in the same rem values Tailwind's theme defines — `--text-2xs` and below
  # are this app's own, added in `app.css`. Every `text-*` utility compiles to `var(--text-<step>)`,
  # so restating the ramp scaled is what makes one setting resize all of them at once. Line heights
  # are left alone deliberately: Tailwind states them as unitless ratios, so they follow.
  @text_scale [
    {"--text-4xs", 0.5625},
    {"--text-3xs", 0.625},
    {"--text-2xs", 0.6875},
    {"--text-xs", 0.75},
    {"--text-sm", 0.875},
    {"--text-base", 1.0},
    {"--text-lg", 1.125}
  ]

  defp font_vars(settings) do
    [
      var("--font-sans", settings[:ui_font], @sans_stack),
      var("--font-mono", settings[:mono_font], @mono_stack)
      | text_vars(settings[:font_scale])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      style -> style
    end
  end

  defp text_vars(scale) when scale in [nil, 100], do: []

  defp text_vars(scale) when is_integer(scale) do
    factor = scale / 100

    for {name, rem} <- @text_scale do
      "#{name}: #{Float.round(rem * factor, 4)}rem;"
    end
  end

  defp text_vars(_scale), do: []

  defp var(_name, family, _stack) when family in [nil, ""], do: nil

  # `EvaWeb.Settings` only stores a family the system actually reported, so this can't be arbitrary
  # text — but it lands in a style attribute, so the quote and backslash that could end the string
  # early come out regardless.
  defp var(name, family, stack) do
    ~s(#{name}: "#{String.replace(family, ~r/["\\;]/, "")}", #{stack};)
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
