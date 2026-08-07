defmodule EvaWeb.Sessions.ExtensionsTest do
  use ExUnit.Case, async: true

  alias EvaWeb.Sessions.Extensions

  # Discovery runs against the real `~/.eva/extensions` — `Eva.Coding.Resources` fixes that root at
  # compile time and there is no way in to redirect it — so every assertion here is about a
  # *particular* row rather than the shape of the whole list. Whatever the machine running this
  # happens to have installed globally is then beside the point.
  defp cwd do
    dir = Path.join(System.tmp_dir!(), "eva_web_ext_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp find(state, name), do: Enum.find(state.extensions, &(&1.name == name))

  defp info(attrs) do
    Map.merge(
      %{
        name: "memory",
        path: nil,
        module: nil,
        node: node(),
        running?: true,
        tool_count: 0,
        commands: [],
        hooks: [],
        event_classes: []
      },
      attrs
    )
  end

  describe "new/4 for extensions on another node" do
    # There is no file to discover, so joining Eva's list against the directory scan would drop the
    # row entirely — which is how MCP would go missing from the panel now that it is an extension.
    test "keeps a row for an extension that is loaded but not on disk" do
      infos = [info(%{name: "mcp", node: :"eva_ext_mcp@127.0.0.1", tool_count: 12})]

      row = cwd() |> Extensions.new(infos, %{}, []) |> find("mcp")

      assert row.loaded?
      assert row.scope == :node
      assert row.node == :"eva_ext_mcp@127.0.0.1"
      assert row.path == nil
      assert row.tool_count == 12
    end

    test "says nothing about the node for an extension compiled into this VM" do
      dir = cwd()
      path = Path.join(dir, "local.exs")
      infos = [info(%{name: "local", path: path, module: Eva.Extension.Local})]

      row = dir |> Extensions.new(infos, %{}, []) |> find("local")

      # It runs here, and saying so on every row would say nothing.
      assert row.node == nil
      assert row.path == path
    end
  end

  describe "new/4 for a project directory awaiting approval" do
    setup do
      dir = cwd()
      extensions_dir = Path.join([dir, ".eva", "extensions"])
      File.mkdir_p!(extensions_dir)
      File.write!(Path.join(extensions_dir, "guard.exs"), "# not approved\n")

      %{cwd: dir, extensions_dir: extensions_dir}
    end

    # Eva holds the whole directory back until someone approves it, and it stays held back for a
    # fresh temporary directory no trust file has ever heard of.
    test "reports the directory rather than its contents", %{
      cwd: cwd,
      extensions_dir: extensions_dir
    } do
      state = Extensions.new(cwd, [], %{}, [])

      assert Extensions.pending?(state)
      assert Path.expand(extensions_dir) in state.pending
      assert find(state, "guard") == nil
    end
  end

  describe "loaded/1" do
    test "counts what is on against everything discovered" do
      row = fn name, loaded? ->
        %{name: name, loaded?: loaded?, tool_count: 0, commands: []}
      end

      state = %{extensions: [row.("a", true), row.("b", false)], diagnostics: [], pending: []}

      assert Extensions.loaded(state) == {1, 2}
    end
  end

  describe "command_text/1" do
    # A command that takes arguments is left mid-typing, with the cursor where the argument goes.
    test "leaves room for an argument when the command takes one" do
      assert Extensions.command_text(%{name: "mcp", arg_hint: "[enable|disable]"}) == "/mcp "
      assert Extensions.command_text(%{name: "mcp", arg_hint: nil}) == "/mcp"
    end
  end

  describe "scope_label/1" do
    test "names all three places an extension can come from" do
      assert Extensions.scope_label(:global) == "global"
      assert Extensions.scope_label(:project) == "project"
      assert Extensions.scope_label(:node) == "node"
    end
  end
end
