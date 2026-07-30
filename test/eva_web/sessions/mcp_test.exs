defmodule EvaWeb.Sessions.MCPTest do
  use ExUnit.Case, async: true

  alias Eva.MCP.Events
  alias EvaWeb.Sessions.MCP

  # `new/2` also reads the developer's own ~/.eva/mcp.json for its targets, so every assertion
  # here is scoped to the server this test wrote into a temporary project.
  defp project_with_mcp_config(json) do
    cwd = Path.join(System.tmp_dir!(), "eva_web_mcp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".eva"))
    File.write!(Path.join([cwd, ".eva", "mcp.json"]), json)
    on_exit(fn -> File.rm_rf(cwd) end)
    cwd
  end

  defp find(state, name), do: Enum.find(state.servers, &(&1.name == name))

  # What `Eva.MCP.SessionServers.list/1` hands a frontend.
  defp info(attrs) do
    Map.merge(
      %{
        name: "demo",
        scope_dir: "/tmp/project",
        type: :stdio,
        config_enabled: true,
        session_enabled: nil,
        status: :connecting,
        tool_count: 0,
        tools: []
      },
      attrs
    )
  end

  defp state(infos), do: MCP.refresh(MCP.empty(), infos)

  describe "new/2" do
    test "decorates a server with the command behind it" do
      cwd =
        project_with_mcp_config("""
        {"mcpServers": {"demo": {"command": "demo-server", "args": ["--stdio"]}}}
        """)

      state = MCP.new(cwd, [info(%{scope_dir: cwd})])

      assert %{target: "demo-server --stdio", transport: :stdio, scope: ^cwd} =
               find(state, "demo")
    end

    test "decorates an http server with its url" do
      cwd =
        project_with_mcp_config("""
        {"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp"}}}
        """)

      state = MCP.new(cwd, [info(%{name: "remote", type: :http, scope_dir: cwd})])

      assert %{target: "https://example.test/mcp"} = find(state, "remote")
    end

    test "reports a config Eva could not parse" do
      cwd = project_with_mcp_config("{ not json")

      assert %{diagnostics: [_ | _]} = MCP.new(cwd, [])
    end

    # Eva's list is the source of truth for which servers exist; the config is read only for the
    # parts of a server that never change.
    test "shows only the servers Eva reported, config or no config" do
      cwd = project_with_mcp_config(~s({"mcpServers": {"demo": {"command": "demo-server"}}}))

      assert MCP.new(cwd, []).servers == []
    end
  end

  describe "refresh/2" do
    test "carries the effective state Eva reported" do
      assert %{status: :connected, enabled?: true, tools: [%{name: "t"}]} =
               state([info(%{status: :connected, tools: [%{name: "t"}], tool_count: 1})])
               |> find("demo")
    end

    test "a disabled server is not enabled and offers nothing" do
      assert %{status: :disabled, enabled?: false, tools: []} =
               state([info(%{status: :disabled, config_enabled: false})]) |> find("demo")
    end
  end

  describe "override reporting" do
    test "a server following its config is not overridden" do
      refute state([info(%{session_enabled: nil})]) |> find("demo") |> Map.fetch!(:overridden?)
    end

    test "a session switching a server off against its config is overridden" do
      server =
        state([info(%{config_enabled: true, session_enabled: false, status: :disabled})])
        |> find("demo")

      assert server.overridden?
      refute server.enabled?
      assert server.config_enabled
    end

    test "a session switching a server on against its config is overridden" do
      server =
        state([info(%{config_enabled: false, session_enabled: true, status: :connected})])
        |> find("demo")

      assert server.overridden?
      assert server.enabled?
      refute server.config_enabled
    end

    # Setting a session toggle to what the file already says leaves nothing to explain, and
    # offering to "save" it would be a no-op the user has to reason about.
    test "a session toggle that agrees with the config is not an override" do
      refute state([info(%{config_enabled: true, session_enabled: true})])
             |> find("demo")
             |> Map.fetch!(:overridden?)
    end
  end

  describe "apply_event/2" do
    test "records the handshake a server list does not carry" do
      event = %Events.ServerConnected{
        server_name: "demo",
        scope_dir: "/tmp/project",
        server_version: "1.2.3",
        protocol_version: "2025-06-18"
      }

      assert %{server_version: "1.2.3", protocol_version: "2025-06-18"} =
               MCP.empty()
               |> MCP.apply_event(event)
               |> MCP.refresh([info(%{status: :connected})])
               |> find("demo")
    end

    test "records the error text behind a failure" do
      event = %Events.ServerError{
        server_name: "demo",
        scope_dir: "/tmp/project",
        error: "Executable not found: demo-server",
        phase: :spawn
      }

      assert %{error: "Executable not found: demo-server"} =
               MCP.empty()
               |> MCP.apply_event(event)
               |> MCP.refresh([info(%{status: :failed})])
               |> find("demo")
    end

    test "records a lost connection" do
      event = %Events.ServerDisconnected{
        server_name: "demo",
        scope_dir: "/tmp/project",
        reason: :process_exit
      }

      server =
        MCP.empty()
        |> MCP.apply_event(event)
        |> MCP.refresh([info(%{status: :failed})])
        |> find("demo")

      assert server.error =~ "process_exit"
    end

    test "surfaces the login command when auth is required" do
      event = %Events.AuthRequired{
        server_name: "demo",
        scope_dir: "/tmp/project",
        login_command: "eva mcp login demo"
      }

      assert %{login_command: "eva mcp login demo"} =
               MCP.empty()
               |> MCP.apply_event(event)
               |> MCP.refresh([info(%{status: :needs_auth})])
               |> find("demo")
    end

    test "a reconnection clears the error it left behind" do
      state =
        MCP.empty()
        |> MCP.apply_event(%Events.ServerError{
          server_name: "demo",
          scope_dir: "/tmp/project",
          error: "boom",
          phase: :spawn
        })
        |> MCP.apply_event(%Events.ServerConnected{
          server_name: "demo",
          scope_dir: "/tmp/project",
          server_version: "1.0.0"
        })
        |> MCP.refresh([info(%{status: :connected})])

      assert %{error: nil} = find(state, "demo")
    end

    # A server the user switched off is not failing at anything, and showing the error it left
    # behind makes a deliberate choice look like a fault.
    test "a switched-off server shows no error" do
      state =
        MCP.empty()
        |> MCP.apply_event(%Events.ServerError{
          server_name: "demo",
          scope_dir: "/tmp/project",
          error: "boom",
          phase: :spawn
        })
        |> MCP.refresh([info(%{status: :disabled, session_enabled: false})])

      assert %{error: nil} = find(state, "demo")
    end

    # Eva folds these into its own snapshots, so status and tools come back from `list/1` and
    # second-guessing them here is how the two disagree.
    test "leaves state alone for an event Eva already accounts for" do
      state = state([info(%{})])

      for event <- [
            %Events.ToolsDiscovered{server_name: "demo", scope_dir: "/tmp/project", tools: []},
            %Events.ResourceUpdated{
              server_name: "demo",
              scope_dir: "/tmp/project",
              uri: "file:///x"
            },
            %Events.ServerLog{
              server_name: "demo",
              scope_dir: "/tmp/project",
              level: :info,
              logger: "stderr",
              message: "listening"
            }
          ] do
        assert MCP.apply_event(state, event) == state
      end
    end
  end

  describe "summaries" do
    # A switched-off server in the denominator would leave the header reading 2/3 forever after a
    # deliberate choice, which looks exactly like one that cannot connect.
    test "counts connected servers against the ones that are switched on" do
      state =
        state([
          info(%{name: "a", status: :connected, tools: [%{name: "t1"}, %{name: "t2"}]}),
          info(%{name: "b", status: :failed}),
          info(%{name: "c", status: :disabled, config_enabled: false})
        ])

      assert MCP.connected(state) == {1, 2}
      assert MCP.tool_count(state) == 2
      assert [%{name: "b"}] = MCP.unhealthy(state)
    end

    test "a server waiting on a login counts as unhealthy" do
      assert [%{name: "a"}] = MCP.unhealthy(state([info(%{name: "a", status: :needs_auth})]))
    end

    test "a switched-off server is not something to report" do
      assert MCP.unhealthy(state([info(%{status: :disabled})])) == []
    end

    # Otherwise switching the last server off would hide the panel that switches it back on.
    test "a session still has servers when every one of them is off" do
      assert MCP.any?(state([info(%{status: :disabled})]))
      refute MCP.any?(MCP.empty())
    end
  end

  describe "source/1" do
    test "splits a prefixed tool name" do
      assert MCP.source("mcp__github__create_issue") == {"github", "create_issue"}
    end

    test "keeps the rest of the name intact when the tool name itself has underscores" do
      assert MCP.source("mcp__a__b__c") == {"a", "b__c"}
    end

    test "ignores names that are not MCP tools" do
      assert MCP.source("read") == nil
      assert MCP.source("mcp__") == nil
      assert MCP.source(nil) == nil
    end
  end

  describe "event?/1" do
    test "recognises every MCP event Eva can emit" do
      for module <- Events.modules() do
        assert MCP.event?(struct(module))
      end
    end

    test "rejects anything else" do
      refute MCP.event?(%Eva.Agent.Events.AgentStart{})
      refute MCP.event?(:not_a_struct)
    end
  end
end
