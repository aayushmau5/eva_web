defmodule EvaWebWeb.TVComponents do
  @moduledoc """
  The session browser prototype's own components: the CRT that stands in for a session, the
  machine/project rows of Boring View, and the detail drawer.

  Kept apart from `EvaWebWeb.ChatComponents` on purpose — this is a prototype of a different UI,
  and mixing it into the chat's components would make it awkward to delete or promote as a whole.
  """
  use EvaWebWeb, :html

  alias EvaWeb.Proto.Fixtures
  alias EvaWeb.Proto.Layout

  @doc """
  One session, drawn as a CRT television.

  The screen carries the session's last few lines and the chin carries the status lamp, so a wall
  of these is readable at two distances: colour from across the room, text up close.
  """
  attr :session, :map, required: true
  attr :selected, :boolean, default: false
  attr :link_count, :integer, default: 0
  attr :class, :string, default: nil
  attr :rest, :global

  def tv(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select"
      phx-value-id={@session.id}
      class={["tv-node", @class]}
      {@rest}
    >
      <div class={["tv-set", @selected && "is-selected"]} data-status={@session.status}>
        <div class="tv-screen">
          <div class="tv-glass">
            <p class="tv-line tv-line--head">
              {Fixtures.status_label(@session.status)}
              <span :if={@session.status == :working} class="tv-caret">▋</span>
            </p>
            <p :for={line <- @session.preview} class="tv-line">{line}</p>
          </div>
          <div class="tv-scan" aria-hidden="true"></div>
          <div class="tv-glare" aria-hidden="true"></div>
        </div>
        <div class="tv-chin">
          <span class="tv-grille" aria-hidden="true"></span>
          <span class="tv-led" aria-hidden="true"></span>
        </div>
        <%!-- The wire in the wireframe: a session with links has something plugged into it. --%>
        <svg :if={@link_count > 0} class="tv-wire" viewBox="0 0 40 46" aria-hidden="true">
          <path d="M2 2 C 2 18, 30 14, 30 26 C 30 36, 12 34, 14 44" />
        </svg>
        <span :if={@link_count > 0} class="tv-links" title={"#{@link_count} connected"}>
          {@link_count}
        </span>
      </div>
      <p class="tv-title">{@session.title}</p>
    </button>
    """
  end

  @doc "The Boring/Fun switch, plus the legend and the placeholder settings control."
  attr :view, :atom, required: true
  attr :counts, :map, required: true

  def browse_header(assigns) do
    ~H"""
    <header class="flex items-center gap-4 border-b border-[var(--proto-line)] px-6 py-4">
      <h1 class="text-lg tracking-[0.2em] text-[var(--proto-phosphor)] uppercase">Eva</h1>

      <div class="ml-auto flex items-center gap-6">
        <.legend counts={@counts} />

        <div class="flex border border-[var(--proto-line)] p-0.5" role="tablist">
          <button
            :for={{value, label} <- [boring: "Boring View", fun: "Fun View"]}
            type="button"
            role="tab"
            aria-selected={to_string(@view == value)}
            phx-click="set_view"
            phx-value-view={value}
            class={[
              "px-4 py-1.5 text-xs tracking-wide transition-colors",
              @view == value && "bg-[var(--proto-line)] text-[var(--proto-phosphor)]",
              @view != value && "text-zinc-400 hover:text-[var(--proto-phosphor)]"
            ]}
          >
            {label}
          </button>
        </div>

        <%!-- Prototype placeholder: the real settings modal lives in the chat UI. --%>
        <button
          type="button"
          title="Settings (not wired up in the prototype)"
          class="border border-[var(--proto-line)] p-2 text-zinc-500 hover:text-zinc-300"
        >
          <.icon name="hero-cog-6-tooth" class="size-4" />
        </button>
      </div>
    </header>
    """
  end

  attr :counts, :map, required: true

  def legend(assigns) do
    ~H"""
    <div class="hidden items-center gap-3 lg:flex">
      <span
        :for={status <- Fixtures.statuses()}
        class="flex items-center gap-1.5 text-3xs tracking-wide text-zinc-500"
      >
        <span class="legend-led" data-status={status}></span>
        {Fixtures.status_label(status)}
        <span class="text-zinc-600">{Map.get(@counts, status, 0)}</span>
      </span>
    </div>
    """
  end

  @doc """
  Boring View: a section per machine, a horizontally scrolling row per project.

  Rows scroll rather than wrap because the wireframe's overflow arrow says the row is the unit —
  one project reads as one shelf of televisions.
  """
  attr :machines, :list, required: true
  attr :projects, :list, required: true
  attr :sessions, :list, required: true
  attr :link_counts, :map, required: true
  attr :selected, :string, default: nil

  def boring_view(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto px-6 py-6">
      <section :for={machine <- @machines} class="mb-10">
        <div class="mb-1 flex items-baseline gap-3">
          <h2 class="text-sm tracking-[0.15em] text-zinc-200 uppercase">{machine.name}</h2>
          <span class="font-mono text-2xs text-zinc-500">{machine.host}</span>
          <span class="text-3xs text-zinc-600">{machine.os}</span>
          <span
            :if={machine.kind == :local}
            class="border border-[var(--proto-line)] px-1.5 py-0.5 text-4xs tracking-wide text-[var(--proto-phosphor)] uppercase"
          >
            local
          </span>
        </div>
        <div class="mb-5 h-px bg-[var(--proto-line)]"></div>

        <div :for={project <- projects_of(@projects, machine.id)} class="mb-6">
          <div class="mb-2 flex items-baseline gap-2">
            <h3 class="font-mono text-xs text-zinc-400">{project.name}</h3>
            <span class="font-mono text-3xs text-zinc-600">{project.path}</span>
          </div>

          <div class="group relative" id={"row-#{project.id}"} phx-hook="ScrollRow">
            <div class="tv-row" data-scroller>
              <.tv
                :for={session <- sessions_of(@sessions, project.id)}
                session={session}
                selected={@selected == session.id}
                link_count={Map.get(@link_counts, session.id, 0)}
              />
            </div>
            <button
              :for={
                {dir, icon, side} <- [
                  {-1, "hero-chevron-left", "left-0"},
                  {1, "hero-chevron-right", "right-0"}
                ]
              }
              type="button"
              data-scroll={dir}
              class={[
                "absolute top-1/2 z-10 -translate-y-1/2 border border-[var(--proto-line)] bg-[var(--proto-bg)]/90 p-1.5",
                "text-zinc-400 opacity-0 transition-opacity hover:text-[var(--proto-phosphor)]",
                "group-hover:opacity-100 data-[hidden]:!opacity-0",
                side
              ]}
            >
              <.icon name={icon} class="size-4" />
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  Fun View: the infinite canvas.

  Everything inside `#canvas-world` is positioned in world units and the hook applies one
  transform to the whole thing, so panning and zooming never touch the individual nodes. Boxes and
  wires are server-rendered for the first paint and recomputed by the hook while a node is dragged.
  """
  attr :sessions, :list, required: true
  attr :positions, :map, required: true
  attr :links, :list, required: true
  attr :link_counts, :map, required: true
  attr :selected, :string, default: nil

  def fun_view(assigns) do
    {project_boxes, machine_boxes} = Layout.boxes(assigns.positions)

    assigns =
      assign(assigns,
        project_boxes: project_boxes,
        machine_boxes: machine_boxes,
        metrics: %{
          "node-w" => Layout.node_w(),
          "node-h" => Layout.node_h(),
          "project-pad" => Layout.project_pad(),
          "machine-pad" => Layout.machine_pad(),
          "label-gap" => Layout.label_gap()
        }
      )

    ~H"""
    <div
      id="canvas"
      class="canvas-viewport relative flex-1 overflow-hidden"
      phx-hook="Canvas"
      data-node-w={@metrics["node-w"]}
      data-node-h={@metrics["node-h"]}
      data-project-pad={@metrics["project-pad"]}
      data-machine-pad={@metrics["machine-pad"]}
      data-label-gap={@metrics["label-gap"]}
    >
      <div id="canvas-world" class="canvas-world">
        <svg class="canvas-wires" aria-hidden="true">
          <path
            :for={{from_id, to_id} <- @links}
            :if={@positions[from_id] && @positions[to_id]}
            data-from={from_id}
            data-to={to_id}
            d={Layout.link_path(Layout.link_endpoints(@positions[from_id], @positions[to_id]))}
            class={[
              "canvas-wire",
              @selected in [from_id, to_id] && "is-lit"
            ]}
          />
        </svg>

        <div
          :for={box <- @machine_boxes}
          class="canvas-box canvas-box--machine"
          data-box="machine"
          data-box-id={box.id}
          style={box_style(box)}
        >
          <span class="canvas-box__label">{box.name}</span>
          <span class="canvas-box__meta">{box.host}</span>
        </div>

        <div
          :for={box <- @project_boxes}
          class="canvas-box canvas-box--project"
          data-box="project"
          data-box-id={box.id}
          style={box_style(box)}
        >
          <span class="canvas-box__label">{box.name}</span>
        </div>

        <.tv
          :for={session <- @sessions}
          :if={@positions[session.id]}
          session={session}
          selected={@selected == session.id}
          link_count={Map.get(@link_counts, session.id, 0)}
          class="tv-node--canvas"
          data-node-id={session.id}
          data-project={session.project_id}
          data-machine={session.machine_id}
          style={node_style(@positions[session.id])}
        />
      </div>

      <div class="pointer-events-none absolute right-4 bottom-4 flex flex-col items-end gap-2">
        <div class="pointer-events-auto flex border border-[var(--proto-line)] bg-[var(--proto-bg)]/90">
          <button
            :for={{action, icon} <- [{"out", "hero-minus"}, {"in", "hero-plus"}]}
            type="button"
            data-zoom={action}
            class="p-2 text-zinc-400 hover:text-[var(--proto-phosphor)]"
          >
            <.icon name={icon} class="size-4" />
          </button>
          <button
            type="button"
            data-zoom="fit"
            class="border-l border-[var(--proto-line)] px-3 text-2xs tracking-wide text-zinc-400 hover:text-[var(--proto-phosphor)]"
          >
            fit
          </button>
        </div>
        <p class="text-3xs text-zinc-600">
          drag a TV to move it · scroll to zoom · drag the void to pan
        </p>
      </div>
    </div>
    """
  end

  @doc "Detail panel for the selected session, with its links as jump targets."
  attr :session, :map, default: nil
  attr :project, :map, default: nil
  attr :machine, :map, default: nil
  attr :connections, :list, default: []

  def detail_drawer(assigns) do
    ~H"""
    <aside
      :if={@session}
      class="flex w-80 shrink-0 flex-col overflow-y-auto border-l border-[var(--proto-line)] bg-[var(--proto-panel)]"
    >
      <div class="flex items-start gap-2 border-b border-[var(--proto-line)] px-4 py-3">
        <div class="min-w-0 flex-1">
          <p class="text-sm text-zinc-100">{@session.title}</p>
          <p class="mt-1 flex items-center gap-1.5 text-2xs text-zinc-500">
            <span class="legend-led" data-status={@session.status}></span>
            {Fixtures.status_label(@session.status)} · {relative(@session.minutes_ago)}
          </p>
        </div>
        <button
          type="button"
          phx-click="select"
          phx-value-id=""
          class="text-zinc-500 hover:text-zinc-300"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 border-b border-[var(--proto-line)] px-4 py-3 text-2xs">
        <dt class="text-zinc-600">machine</dt>
        <dd class="text-zinc-300">
          {@machine.name} <span class="text-zinc-600">{@machine.host}</span>
        </dd>
        <dt class="text-zinc-600">project</dt>
        <dd class="font-mono text-zinc-300">{@project.path}</dd>
        <dt class="text-zinc-600">model</dt>
        <dd class="font-mono text-zinc-300">{@session.model}</dd>
        <dt class="text-zinc-600">turns</dt>
        <dd class="text-zinc-300">{@session.turns}</dd>
        <dt class="text-zinc-600">tokens</dt>
        <dd class="text-zinc-300">{format_tokens(@session.tokens)}</dd>
      </dl>

      <div class="border-b border-[var(--proto-line)] px-4 py-3">
        <p class="mb-2 text-3xs tracking-[0.15em] text-zinc-600 uppercase">last output</p>
        <pre class="tv-transcript">{Enum.join(@session.preview, "\n")}</pre>
      </div>

      <div class="px-4 py-3">
        <p class="mb-2 text-3xs tracking-[0.15em] text-zinc-600 uppercase">
          connections ({length(@connections)})
        </p>
        <p :if={@connections == []} class="text-2xs text-zinc-600">nothing plugged in.</p>
        <button
          :for={%{session: other, machine: other_machine, direction: direction} <- @connections}
          type="button"
          phx-click="select"
          phx-value-id={other.id}
          class="mb-1.5 flex w-full items-start gap-2 border border-[var(--proto-line)] px-2 py-1.5 text-left hover:border-[var(--proto-phosphor)]/40"
        >
          <span class="mt-0.5 text-2xs text-zinc-600">{if direction == :out, do: "→", else: "←"}</span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-2xs text-zinc-300">{other.title}</span>
            <span class="block text-3xs text-zinc-600">{other_machine.name}</span>
          </span>
          <span class="legend-led mt-1" data-status={other.status}></span>
        </button>
      </div>

      <div class="mt-auto border-t border-[var(--proto-line)] p-3">
        <button
          type="button"
          disabled
          class="w-full border border-[var(--proto-line)] py-2 text-xs text-zinc-500"
          title="Mock session — there is no transcript behind it"
        >
          Open chat
        </button>
      </div>
    </aside>
    """
  end

  # -- Private --

  defp projects_of(projects, machine_id),
    do: Enum.filter(projects, &(&1.machine_id == machine_id))

  defp sessions_of(sessions, project_id),
    do: Enum.filter(sessions, &(&1.project_id == project_id))

  defp box_style(box) do
    "left:#{box.x}px;top:#{box.y}px;width:#{box.w}px;height:#{box.h}px"
  end

  defp node_style(pos), do: "left:#{pos.x}px;top:#{pos.y}px"

  defp relative(0), do: "just now"
  defp relative(m) when m < 60, do: "#{m}m ago"
  defp relative(m) when m < 1440, do: "#{div(m, 60)}h ago"
  defp relative(m), do: "#{div(m, 1440)}d ago"

  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: to_string(n)
end
