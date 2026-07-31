defmodule EvaWebWeb.BrowseLive do
  @moduledoc """
  Prototype of the session browser: every session Eva knows about, on every machine, as a wall of
  televisions.

  Two views over the same data. **Boring View** groups by machine, then by project, and puts each
  project's sessions in a scrolling row. **Fun View** is an infinite canvas where the same sessions
  are nodes you can drag, inside boundary boxes that follow them, wired to the sessions they are
  connected to.

  Everything here is fabricated — see `EvaWeb.Proto.Fixtures`. No `EvaWeb.Sessions.Runner` is
  started and nothing is read from `~/.eva`, so this view can show four statuses at once and links
  that cross a machine boundary, neither of which real local data can do yet.
  """
  use EvaWebWeb, :live_view

  import EvaWebWeb.TVComponents

  alias EvaWeb.Proto.Fixtures
  alias EvaWeb.Proto.Layout
  alias EvaWebWeb.Layouts

  # Slow enough that a change is something you notice rather than a strobe.
  @tick_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@tick_ms, self(), :tick)

    sessions = Map.new(Fixtures.sessions(), &{&1.id, &1})
    links = Fixtures.links()

    {:ok,
     socket
     |> assign(
       page_title: "Eva · sessions",
       view: :boring,
       machines: Fixtures.machines(),
       projects: Fixtures.projects(),
       order: Enum.map(Fixtures.sessions(), & &1.id),
       sessions: sessions,
       links: links,
       link_counts: link_counts(links),
       positions: Layout.initial_positions(),
       empty_rects: %{},
       selected: nil,
       moved: nil,
       dragging?: false
     )}
  end

  # -- Events --

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(boring fun) do
    {:noreply, assign(socket, :view, String.to_existing_atom(view))}
  end

  def handle_event("select", %{"id" => ""}, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    # Clicking the open session again closes the drawer, so the canvas can be cleared without
    # having to aim at the little x.
    selected = if socket.assigns.selected == id, do: nil, else: id
    {:noreply, assign(socket, :selected, selected)}
  end

  # A dropped session. If it landed inside another project's box, that is a move: the session now
  # belongs to that project, and to whichever machine the project is on.
  #
  # Dropping into open space is just a move on the canvas — the session keeps its project, whose box
  # then stretches to reach it. That stretch is the rule made visible, and the way out of it is to
  # drop the session somewhere that means something.
  def handle_event("node_moved", %{"id" => id, "x" => x, "y" => y}, socket) do
    before = socket.assigns.positions
    positions = Map.put(before, id, %{x: x, y: y})
    socket = assign(socket, :positions, positions)
    session = socket.assigns.sessions[id]

    target =
      session &&
        Layout.drop_target(
          Map.values(socket.assigns.sessions),
          positions,
          socket.assigns.empty_rects,
          id
        )

    if target && target != session.project_id do
      {:noreply, reparent(socket, session, target, before)}
    else
      {:noreply, socket}
    end
  end

  # The ticker is held off for the duration of a drag. A status change re-renders the whole node
  # comprehension — including each node's `style` — which would yank the TV out from under the
  # cursor mid-drag.
  def handle_event("drag_start", _params, socket),
    do: {:noreply, assign(socket, :dragging?, true)}

  def handle_event("drag_end", _params, socket), do: {:noreply, assign(socket, :dragging?, false)}

  @impl true
  def handle_info({:clear_move, id}, socket) do
    {:noreply, if(socket.assigns.moved == id, do: assign(socket, :moved, nil), else: socket)}
  end

  def handle_info(:tick, %{assigns: %{dragging?: true}} = socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    case Fixtures.advance(socket.assigns.sessions) do
      {id, status} ->
        {:noreply,
         update(socket, :sessions, fn sessions ->
           Map.update!(sessions, id, &%{&1 | status: status, minutes_ago: 0})
         end)}

      nil ->
        {:noreply, socket}
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        ordered: Enum.map(assigns.order, &assigns.sessions[&1]),
        counts: status_counts(assigns.sessions),
        detail: detail(assigns)
      )

    ~H"""
    <div class="proto flex h-screen flex-col bg-[var(--proto-bg)] text-zinc-300">
      <.browse_header view={@view} counts={@counts} />

      <div class="flex min-h-0 flex-1">
        <.boring_view
          :if={@view == :boring}
          machines={@machines}
          projects={@projects}
          sessions={@ordered}
          link_counts={@link_counts}
          selected={@selected}
          moved={@moved}
        />

        <.fun_view
          :if={@view == :fun}
          sessions={@ordered}
          positions={@positions}
          empty_rects={@empty_rects}
          links={@links}
          link_counts={@link_counts}
          selected={@selected}
          moved={@moved}
        />

        <.detail_drawer
          session={@detail[:session]}
          project={@detail[:project]}
          machine={@detail[:machine]}
          connections={@detail[:connections] || []}
        />
      </div>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  # -- Private --

  # How long the landed session stays highlighted. Long enough to find it after it has jumped
  # across the canvas into another machine, short enough not to become part of the picture.
  @move_flash_ms 1_600

  defp reparent(socket, session, project_id, positions_before) do
    project = Enum.find(socket.assigns.projects, &(&1.id == project_id))
    source = session.project_id

    # Measured before the move is applied, so it is the box as the user last saw it rather than the
    # nothing that is left once the session has gone.
    source_rect =
      Layout.project_rect(
        source,
        Map.values(socket.assigns.sessions),
        positions_before,
        socket.assigns.empty_rects
      )

    sessions =
      Map.put(socket.assigns.sessions, session.id, %{
        session
        | project_id: project.id,
          machine_id: project.machine_id
      })

    empty_rects =
      socket.assigns.empty_rects
      # The target just gained a session, so it has real bounds again and no longer needs a
      # remembered rect; the source keeps one only if that was its last session.
      |> Map.delete(project.id)
      |> remember(source, source_rect, sessions)

    Process.send_after(self(), {:clear_move, session.id}, @move_flash_ms)

    socket
    |> assign(:sessions, sessions)
    |> assign(:empty_rects, empty_rects)
    |> assign(:moved, session.id)
  end

  defp remember(rects, project_id, rect, sessions) do
    emptied? = not Enum.any?(Map.values(sessions), &(&1.project_id == project_id))

    if emptied? and is_map(rect) do
      Map.put(rects, project_id, Layout.at_least_one_node(rect))
    else
      rects
    end
  end

  defp status_counts(sessions) do
    sessions |> Map.values() |> Enum.frequencies_by(& &1.status)
  end

  defp link_counts(links) do
    links
    |> Enum.flat_map(fn {from, to} -> [from, to] end)
    |> Enum.frequencies()
  end

  defp detail(%{selected: nil}), do: %{}

  defp detail(%{selected: id} = assigns) do
    case assigns.sessions[id] do
      nil ->
        %{}

      session ->
        project = Enum.find(assigns.projects, &(&1.id == session.project_id))
        machine = Enum.find(assigns.machines, &(&1.id == session.machine_id))

        %{
          session: session,
          project: project,
          machine: machine,
          connections: connections(id, assigns)
        }
    end
  end

  # Both directions, because "what did this session feed into" and "what fed into it" are equally
  # what you want to know when you click one.
  defp connections(id, assigns) do
    assigns.links
    |> Enum.flat_map(fn
      {^id, other} -> [{:out, other}]
      {other, ^id} -> [{:in, other}]
      _ -> []
    end)
    |> Enum.flat_map(fn {direction, other_id} ->
      case assigns.sessions[other_id] do
        nil ->
          []

        other ->
          [
            %{
              direction: direction,
              session: other,
              machine: Enum.find(assigns.machines, &(&1.id == other.machine_id))
            }
          ]
      end
    end)
  end
end
