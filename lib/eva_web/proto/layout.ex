defmodule EvaWeb.Proto.Layout do
  @moduledoc """
  World coordinates for Fun View: where each session TV starts out, and the boundary boxes drawn
  around projects and machines.

  Two rules, and only two, because the canvas hook in `app.js` has to reproduce both while a node
  is being dragged:

    * a project box is the bounding box of its sessions, grown by `project_pad/0`, with
      `label_gap/0` of extra room at the top for its name;
    * a machine box is the bounding box of its project boxes, grown by `machine_pad/0`, with the
      same extra room at the top.

  Keeping the constants here and handing them to JS as data attributes is what stops the two
  implementations drifting apart.
  """

  alias EvaWeb.Proto.Fixtures

  # A TV plus the two-line title underneath it. Mirrored in CSS by `.tv-node`.
  @node_w 176
  @node_h 158

  @gap 30
  @cols 3

  @project_pad 22
  @machine_pad 30
  @label_gap 30

  @doc "Width of one session node, in world units."
  def node_w, do: @node_w
  @doc "Height of one session node, in world units."
  def node_h, do: @node_h
  @doc "Padding between a project's sessions and its boundary box."
  def project_pad, do: @project_pad
  @doc "Padding between a machine's project boxes and its boundary box."
  def machine_pad, do: @machine_pad
  @doc "Extra room at the top of a boundary box, for its label."
  def label_gap, do: @label_gap

  @doc """
  Starting position of every session, keyed by id.

  The first machine is given its own column on the left and the rest are stacked to its right,
  which is the arrangement in the wireframe — the local machine reads as the thing you are sitting
  at, and remote machines as a set of boxes off to the side.
  """
  @spec initial_positions() :: %{String.t() => %{x: number(), y: number()}}
  def initial_positions do
    machines = Fixtures.machines()
    sizes = Map.new(machines, &{&1.id, machine_size(&1.id)})

    machines
    |> machine_origins(sizes)
    |> Enum.flat_map(fn {machine_id, origin} -> place_machine(machine_id, origin) end)
    |> Map.new()
  end

  @doc """
  Boundary boxes for the given sessions and positions, as `{project_boxes, machine_boxes}`.

  Derived rather than stored, so a box can never disagree with where its sessions actually are —
  which is also what makes a box a meaningful drop target: dropping a session inside one is the
  same statement as the box being drawn around it.

  `remembered` is the exception, and only covers projects that have been emptied by dragging their
  last session away. A project with nothing in it has no bounds to compute, and a box that vanished
  is a box you can never put anything back into, so its last rect is kept as a landing pad. See
  `EvaWebWeb.BrowseLive`.
  """
  @spec boxes([map()], %{String.t() => %{x: number(), y: number()}}, %{String.t() => map()}) ::
          {[map()], [map()]}
  def boxes(sessions, positions, remembered \\ %{}) do
    project_boxes =
      for project <- Fixtures.projects(),
          rect = project_rect(project.id, sessions, positions, remembered) do
        project
        |> Map.take([:id, :name, :path, :machine_id])
        |> Map.merge(rect)
      end

    machine_boxes =
      for machine <- Fixtures.machines(),
          children = Enum.filter(project_boxes, &(&1.machine_id == machine.id)),
          children != [] do
        corners =
          Enum.flat_map(children, fn box ->
            [{box.x, box.y - @label_gap}, {box.x + box.w, box.y + box.h}]
          end)

        machine
        |> Map.take([:id, :name, :host, :kind, :os])
        |> Map.merge(bounds(corners, @machine_pad))
      end

    {project_boxes, machine_boxes}
  end

  @doc """
  The rect a project's box occupies, or nil when it has no sessions and none is remembered.
  """
  @spec project_rect(String.t(), [map()], %{String.t() => map()}, %{String.t() => map()}) ::
          map() | nil
  def project_rect(project_id, sessions, positions, remembered \\ %{}) do
    points =
      sessions
      |> Enum.filter(&(&1.project_id == project_id))
      |> Enum.flat_map(fn session ->
        case positions[session.id] do
          nil -> []
          pos -> [{pos.x, pos.y}, {pos.x + @node_w, pos.y + @node_h}]
        end
      end)

    case points do
      [] -> remembered[project_id]
      points -> bounds(points, @project_pad)
    end
  end

  @doc """
  Re-flows one project's sessions into the same grid `initial_positions/0` uses, anchored at the
  top-left of where its box already is.

  Anchoring rather than re-deriving the origin is what makes this a tidy and not an undo: a project
  you deliberately dragged to the far side of the canvas stays there, it just stops being a heap.
  Sessions keep reading order — top-to-bottom, then left-to-right — so tidying compacts the
  arrangement you can see instead of shuffling it.
  """
  @spec tidy(String.t(), [map()], %{String.t() => map()}) :: %{String.t() => map()}
  def tidy(project_id, sessions, positions) do
    case project_rect(project_id, sessions, positions) do
      nil ->
        positions

      rect ->
        sessions
        |> Enum.filter(&(&1.project_id == project_id))
        |> Enum.sort_by(&{positions[&1.id].y, positions[&1.id].x})
        |> Enum.with_index()
        |> Enum.reduce(positions, fn {session, i}, acc ->
          Map.put(acc, session.id, %{
            x: rect.x + @project_pad + rem(i, @cols) * (@node_w + @gap),
            y: rect.y + @project_pad + div(i, @cols) * (@node_h + @gap)
          })
        end)
    end
  end

  @doc """
  The project box a dropped session landed in, or nil if it was dropped in open space.

  The session being dropped is excluded from the boxes it is tested against. Without that its own
  project's box would have stretched to follow it during the drag, and every drop would resolve to
  "it is still where it was". The smallest containing box wins, since boxes can overlap once things
  have been dragged around and the tighter one is the more specific claim.
  """
  @spec drop_target([map()], %{String.t() => map()}, %{String.t() => map()}, String.t()) ::
          String.t() | nil
  def drop_target(sessions, positions, remembered, session_id) do
    case positions[session_id] do
      nil ->
        nil

      pos ->
        {x, y} = anchor(pos)
        others = Enum.reject(sessions, &(&1.id == session_id))
        {project_boxes, _machine_boxes} = boxes(others, positions, remembered)

        project_boxes
        |> Enum.filter(&(x >= &1.x and x <= &1.x + &1.w and y >= &1.y and y <= &1.y + &1.h))
        |> Enum.sort_by(&(&1.w * &1.h))
        |> case do
          [box | _rest] -> box.id
          [] -> nil
        end
    end
  end

  @doc """
  The point on a node that decides which box it was dropped into: the middle of the screen, not of
  the node, since the node's lower third is its title and you aim with the picture.
  """
  @spec anchor(%{x: number(), y: number()}) :: {number(), number()}
  def anchor(pos), do: {pos.x + @node_w / 2, pos.y + @node_h * 0.38}

  @doc "Grows a rect to at least one node plus padding, so an emptied box stays big enough to aim at."
  @spec at_least_one_node(map()) :: map()
  def at_least_one_node(rect) do
    %{
      rect
      | w: max(rect.w, @node_w + @project_pad * 2),
        h: max(rect.h, @node_h + @project_pad * 2)
    }
  end

  @doc """
  Where a link should leave one node and enter another, as `{x1, y1, x2, y2}` in world units.

  Anchored on the side of each node that faces the other, so a wire between two TVs stacked
  vertically leaves the bottom rather than looping out of the right edge and back.
  """
  @spec link_endpoints(%{x: number(), y: number()}, %{x: number(), y: number()}) ::
          {number(), number(), number(), number()}
  def link_endpoints(from, to) do
    # The screen's vertical middle, not the node's — the node's lower third is the title text.
    fy = from.y + @node_h * 0.38
    ty = to.y + @node_h * 0.38

    if to.x >= from.x do
      {from.x + @node_w, fy, to.x, ty}
    else
      {from.x, fy, to.x + @node_w, ty}
    end
  end

  @doc "An SVG path for a link, bowed horizontally so crossing wires stay tellable apart."
  @spec link_path({number(), number(), number(), number()}) :: String.t()
  def link_path({x1, y1, x2, y2}) do
    bow = max(60, abs(x2 - x1) * 0.45)
    "M #{r(x1)} #{r(y1)} C #{r(x1 + bow)} #{r(y1)}, #{r(x2 - bow)} #{r(y2)}, #{r(x2)} #{r(y2)}"
  end

  # -- Private --

  defp r(n), do: Float.round(n * 1.0, 1)

  defp bounds(points, pad) do
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    x = Enum.min(xs) - pad
    y = Enum.min(ys) - pad

    %{
      x: x,
      y: y,
      w: Enum.max(xs) - Enum.min(xs) + pad * 2,
      h: Enum.max(ys) - Enum.min(ys) + pad * 2
    }
  end

  defp machine_origins([first | rest], sizes) do
    {_, first_h} = sizes[first.id]
    right_x = elem(sizes[first.id], 0) + 150

    {origins, _} =
      Enum.map_reduce(rest, 0, fn machine, y ->
        {_, h} = sizes[machine.id]
        {{machine.id, {right_x, y}}, y + h + 90}
      end)

    # The left column is centred against the right one when it is the shorter of the two, so the
    # canvas opens looking balanced rather than top-heavy.
    right_h = Enum.reduce(rest, 0, fn m, acc -> acc + elem(sizes[m.id], 1) + 90 end) - 90
    first_y = max(0, (right_h - first_h) / 2)

    [{first.id, {0, first_y}} | origins]
  end

  # The size a machine's contents occupy, before its own padding — projects stacked vertically,
  # each project's sessions wrapped at `@cols` per row.
  defp machine_size(machine_id) do
    machine_id
    |> projects_of()
    |> Enum.reduce({0, 0}, fn project, {w, h} ->
      {pw, ph} = project_size(project.id)
      {max(w, pw), h + ph + @gap + @label_gap}
    end)
  end

  defp project_size(project_id) do
    count = project_id |> sessions_of() |> length()
    cols = min(count, @cols)
    rows = ceil(count / @cols)

    {cols * @node_w + max(cols - 1, 0) * @gap + @project_pad * 2,
     rows * @node_h + max(rows - 1, 0) * @gap + @project_pad * 2}
  end

  defp place_machine(machine_id, {mx, my}) do
    inner_x = mx + @machine_pad + @project_pad
    inner_y = my + @machine_pad + @label_gap

    machine_id
    |> projects_of()
    |> Enum.flat_map_reduce(inner_y, fn project, y ->
      {_pw, ph} = project_size(project.id)

      {place_project(project.id, {inner_x, y + @label_gap + @project_pad}),
       y + ph + @gap + @label_gap}
    end)
    |> elem(0)
  end

  defp place_project(project_id, {x, y}) do
    project_id
    |> sessions_of()
    |> Enum.with_index()
    |> Enum.map(fn {session, i} ->
      col = rem(i, @cols)
      row = div(i, @cols)

      {session.id, %{x: x + col * (@node_w + @gap), y: y + row * (@node_h + @gap)}}
    end)
  end

  defp projects_of(machine_id),
    do: Enum.filter(Fixtures.projects(), &(&1.machine_id == machine_id))

  defp sessions_of(project_id),
    do: Enum.filter(Fixtures.sessions(), &(&1.project_id == project_id))
end
