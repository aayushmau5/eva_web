defmodule EvaWeb.Sessions.Extensions do
  @moduledoc """
  A session's view of its extensions, for the panel and its toggles.

  Eva's `Eva.Extension.Set` is the source of truth for what is *loaded*: it compiles the `.exs`
  files, starts a process for the stateful ones, and `list/1` hands that out in the shape a
  frontend needs. What it cannot hand out is an extension that isn't loaded — switching one off
  drops it from the set entirely — and a panel whose rows vanish when you use them is a panel you
  can't switch anything back on with.

  So discovery is done here as well, against the same directories Eva reads, and the two are
  joined: every `.exs` on disk is a row, and Eva's list says which of them made it in. An
  extension that is on disk and absent from that list is off — either because this session
  switched it off, or because it failed to load, which is what `diagnostics` is for.

  Not every extension is on disk, though. One that runs on its own node — MCP is the first —
  is never scanned for and never compiled here; it announces itself to `Eva.Cluster` and the
  session instantiates it remotely. There is no file to find and nothing to switch back on if
  its row were dropped, so those rows come from Eva's list alone and say which node they are on
  instead of which file they came from.
  """

  alias Eva.Coding.Resources
  alias Eva.Extension.Loader
  alias Eva.Core.Extension.Spec

  @type status :: :running | :loaded | :off

  @typedoc """
  One command, as the panel offers it.

  `active?` is false for a name another extension already claimed — Eva keeps the first and drops
  the rest, so the row is still worth showing but typing it would reach someone else.
  """
  @type command :: %{
          name: String.t(),
          description: String.t() | nil,
          arg_hint: String.t() | nil,
          active?: boolean()
        }

  @typedoc """
  One extension as the panel renders it.

  `loaded?` is what the toggle reflects. `status` splits that further: an extension with only
  tools or guidelines is merged into the session as plain data and never gets a process, which is
  not the same thing as one whose process died.

  `path` and `module` are nil for an extension running on another node: there is no file here and
  no module loaded in this VM. `node` is what it has instead.
  """
  @type extension :: %{
          name: String.t(),
          path: String.t() | nil,
          scope: :global | :project | :node,
          node: node() | nil,
          module: module() | nil,
          status: status(),
          loaded?: boolean(),
          tool_count: non_neg_integer(),
          commands: [command()],
          hooks: [atom()],
          event_classes: [atom()]
        }

  @type t :: %{extensions: [extension()], diagnostics: [String.t()], pending: [String.t()]}

  @doc "An empty state, for a view with no session open."
  @spec empty() :: t()
  def empty, do: %{extensions: [], diagnostics: [], pending: []}

  @doc """
  Builds the panel state from Eva's three answers for a session in `cwd`.

  `infos` is `Eva.Coding.Session.list_extensions/1`, `commands` is `extension_commands/1`, and
  `diagnostics` is `extension_diagnostics/1`.
  """
  @spec new(String.t(), [map()], map(), [String.t()]) :: t()
  def new(cwd, infos, commands, diagnostics) do
    loaded = Map.new(infos, &{&1.name, &1})
    {candidates, pending} = candidates(cwd)

    from_disk =
      Enum.map(candidates, fn {name, path} ->
        decorate(name, path, cwd, Map.get(loaded, name), commands)
      end)

    # Everything Eva loaded that no file here accounts for: an extension on another node, or one
    # loaded from an explicit path outside the scanned directories. A row built from the info
    # alone, since there is no candidate to join it to.
    found = MapSet.new(candidates, fn {name, _path} -> name end)

    remote =
      infos
      |> Enum.reject(&MapSet.member?(found, &1.name))
      |> Enum.map(&decorate(&1.name, nil, cwd, &1, commands))

    %{
      extensions: from_disk ++ remote,
      diagnostics: diagnostics |> Enum.map(&to_string/1) |> Enum.reject(&about?(&1, pending)),
      pending: pending
    }
  end

  # Eva reports a directory it held back as a diagnostic ending in "run /trust-extensions". The
  # panel has a button for that and names the same directory above, so repeating the sentence would
  # only ask twice. Matched by the path it opens with, which is the directory itself.
  defp about?(diagnostic, pending) do
    Enum.any?(pending, &String.starts_with?(diagnostic, &1))
  end

  @doc "True when the session has any extension at all, switched on or not."
  @spec any?(t()) :: boolean()
  def any?(%{extensions: extensions}), do: extensions != []

  @doc """
  Directories full of extensions that Eva skipped for want of consent.

  A project's `.eva/extensions` is code from whoever wrote the repository, and it runs before the
  first prompt — so nothing in it loads until the user approves the directory. These are the
  directories waiting on that, and the panel's approve button is what answers them.
  """
  @spec pending?(t()) :: boolean()
  def pending?(%{pending: pending}), do: pending != []

  @doc """
  How many extensions are loaded, over how many are on disk.

  Unlike MCP servers there is no connecting state to wait through: an extension either compiled
  and ran `setup/1` at session start or it didn't, so this counts the whole discovered set rather
  than only the ones that were meant to be on.
  """
  @spec loaded(t()) :: {non_neg_integer(), non_neg_integer()}
  def loaded(%{extensions: extensions}) do
    {Enum.count(extensions, & &1.loaded?), length(extensions)}
  end

  @doc "Total number of tools extensions are adding to the model's list."
  @spec tool_count(t()) :: non_neg_integer()
  def tool_count(%{extensions: extensions}) do
    extensions |> Enum.map(& &1.tool_count) |> Enum.sum()
  end

  @doc "Every command the user can currently type, across every loaded extension."
  @spec commands(t()) :: [command()]
  def commands(%{extensions: extensions}) do
    extensions |> Enum.flat_map(& &1.commands) |> Enum.filter(& &1.active?)
  end

  @doc "Human label for where an extension was found."
  @spec scope_label(:global | :project | :node) :: String.t()
  def scope_label(:project), do: "project"
  def scope_label(:global), do: "global"
  def scope_label(:node), do: "node"

  @doc "What the composer should be filled with to run `command`."
  @spec command_text(command()) :: String.t()
  def command_text(%{name: name, arg_hint: hint}) when is_binary(hint) and hint != "" do
    "/#{name} "
  end

  def command_text(%{name: name}), do: "/#{name}"

  # -- Private --

  # The same discovery Eva does, minus the compiling: `candidates/2` is a directory read, and it
  # already resolves a project file shadowing a global one of the same name, and holds back a
  # directory that hasn't been approved.
  defp candidates(cwd) do
    Loader.candidates(%Resources{cwd: cwd}, [])
  rescue
    # A `.eva` that is a file, or a directory that can't be read, is not worth a blank panel.
    _error -> {[], []}
  end

  defp decorate(name, path, cwd, nil, _commands) do
    %{
      name: name,
      path: path,
      scope: scope(path, cwd),
      node: nil,
      module: nil,
      status: :off,
      loaded?: false,
      tool_count: 0,
      commands: [],
      hooks: [],
      event_classes: []
    }
  end

  defp decorate(name, path, cwd, info, commands) do
    # Eva's own path wins: it is the file that was actually compiled. Nil on both sides means an
    # extension on another node, which has no file at all.
    path = Map.get(info, :path) || path

    %{
      name: name,
      path: path,
      scope: scope(path, cwd),
      node: remote_node(info),
      module: info.module,
      status: if(info.running?, do: :running, else: :loaded),
      loaded?: true,
      tool_count: info.tool_count,
      commands: commands_for(info, commands),
      hooks: info.hooks,
      event_classes: info.event_classes
    }
  end

  # Only worth showing when it isn't us: every locally compiled extension runs on this node, and
  # saying so on every row would say nothing.
  defp remote_node(info) do
    case Map.get(info, :node) do
      nil -> nil
      remote when remote == node() -> nil
      remote -> remote
    end
  end

  # `Eva.Extension.Set.list/1` carries only command names; the descriptions and argument hints
  # live in the merged command map, which is also the only thing that knows who won a clash.
  defp commands_for(info, commands) do
    Enum.map(info.commands, fn name ->
      case Map.get(commands, name) do
        {owner, %Spec.Command{} = command} when owner == info.name ->
          %{
            name: name,
            description: command.description,
            arg_hint: command.arg_hint,
            active?: true
          }

        _other ->
          %{name: name, description: nil, arg_hint: nil, active?: false}
      end
    end)
  end

  defp scope(nil, _cwd), do: :node

  defp scope(path, cwd) do
    project_dir = Path.expand(Path.join([cwd, ".eva", "extensions"]))
    if String.starts_with?(path, project_dir <> "/"), do: :project, else: :global
  end
end
