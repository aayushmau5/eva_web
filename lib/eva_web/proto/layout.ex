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
  Boundary boxes for the given positions, as `{project_boxes, machine_boxes}`.

  Recomputed from scratch on every render rather than stored, so a box can never disagree with
  where its sessions actually are.
  """
  @spec boxes(%{String.t() => %{x: number(), y: number()}}) :: {[map()], [map()]}
  def boxes(positions) do
    project_boxes =
      for project <- Fixtures.projects(),
          points = session_points(project.id, positions),
          points != [] do
        project
        |> Map.take([:id, :name, :path, :machine_id])
        |> Map.merge(bounds(points, @project_pad))
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

  # Both corners of every session in the project, so `bounds/2` sees the node's extent and not just
  # its top-left origin.
  defp session_points(project_id, positions) do
    project_id
    |> sessions_of()
    |> Enum.flat_map(fn session ->
      case positions[session.id] do
        nil -> []
        pos -> [{pos.x, pos.y}, {pos.x + @node_w, pos.y + @node_h}]
      end
    end)
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
