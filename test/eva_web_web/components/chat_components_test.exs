defmodule EvaWebWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvaWebWeb.ChatComponents

  defp render(text), do: text |> ChatComponents.markdown() |> Phoenix.HTML.safe_to_string()

  defp mcp_server(attrs) do
    Map.merge(
      %{
        name: "github",
        scope: :global,
        transport: :stdio,
        target: "npx -y @modelcontextprotocol/server-github",
        status: :connected,
        enabled?: true,
        config_enabled: true,
        session_enabled: nil,
        overridden?: false,
        tools: [],
        server_version: "1.2.3",
        protocol_version: "2025-06-18",
        error: nil,
        login_command: nil
      },
      attrs
    )
  end

  defp mcp_state(servers, diagnostics \\ []),
    do: %{servers: servers, diagnostics: diagnostics, meta: %{}}

  describe "markdown/1" do
    test "renders emphasis and lists" do
      html = render("Some **bold** and *italic*.\n\n- one\n- two\n")

      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<ul>"
      assert html =~ "<li>one</li>"
    end

    test "renders fenced code with its language" do
      html = render("```elixir\ndef hello, do: :world\n```")

      assert html =~ ~s|<code class="language-elixir">|
      assert html =~ "hello"
    end

    # Tokens come back wrapped in per-colour spans, so the source is no longer contiguous text.
    test "syntax highlights fenced code" do
      html = render("```elixir\ndef hello, do: :world\n```")

      assert html =~ ~s|<span style="color:|
      assert html =~ "background-color:#282828"
    end

    test "leaves code without a language alone but still themed" do
      html = render("```\njust text\n```")

      assert html =~ "<pre"
      assert html =~ "just text"
    end

    test "keeps single newlines visible" do
      # The sanitizer normalises the void tag, so this is <br> rather than <br />.
      assert render("Line one\nLine two") =~ "<br>"
    end
  end

  # The model's output is untrusted — the read tool alone can put arbitrary repo file contents into
  # a message — and it goes through raw/1, so sanitizing is the only thing standing between a file
  # on disk and live markup.
  describe "markdown/1 sanitization" do
    test "drops script tags" do
      html = render("hi\n\n<script>alert('xss')</script>")

      refute html =~ "<script"
      refute html =~ "alert("
    end

    test "drops inline event handlers" do
      html = render(~s|<img src=x onerror="alert('xss')">|)

      refute html =~ "onerror"
      refute html =~ "alert("
    end

    test "drops javascript: urls" do
      html = render(~s|<a href="javascript:alert(1)">click</a>|)

      refute html =~ "javascript:"
    end

    test "drops raw iframes" do
      refute render(~s|<iframe src="https://evil.example"></iframe>|) =~ "<iframe"
    end

    test "escapes rather than executes html found inside a code fence" do
      html = render("```\n<script>alert('xss')</script>\n```")

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "mcp_indicator/1" do
    test "counts connected servers against configured ones" do
      html =
        render_component(&ChatComponents.mcp_indicator/1,
          mcp: mcp_state([mcp_server(%{}), mcp_server(%{name: "exa", status: :failed})])
        )

      assert html =~ "MCP"
      assert html =~ "1/2"
    end

    test "stays out of the way when no servers are configured" do
      assert render_component(&ChatComponents.mcp_indicator/1, mcp: mcp_state([])) =~ ""
      refute render_component(&ChatComponents.mcp_indicator/1, mcp: mcp_state([])) =~ "mcp-toggle"
    end

    test "shows up for a config that failed to parse even with no servers" do
      html = render_component(&ChatComponents.mcp_indicator/1, mcp: mcp_state([], ["bad json"]))

      assert html =~ "mcp-toggle"
    end
  end

  describe "mcp_panel/1" do
    test "renders nothing while closed" do
      html =
        render_component(&ChatComponents.mcp_panel/1,
          mcp: mcp_state([mcp_server(%{})]),
          open: false
        )

      refute html =~ "mcp-panel"
    end

    test "lists a server with its transport, scope and versions" do
      html =
        render_component(&ChatComponents.mcp_panel/1,
          mcp: mcp_state([mcp_server(%{})]),
          open: true
        )

      assert html =~ "github"
      assert html =~ "stdio"
      assert html =~ "global"
      assert html =~ "v1.2.3"
      assert html =~ "2025-06-18"
      assert html =~ "connected"
    end

    test "lists the tools a server exposes" do
      tools = [%{name: "create_issue", description: "Opens an issue", input_schema: %{}}]

      html =
        render_component(&ChatComponents.mcp_panel/1,
          mcp: mcp_state([mcp_server(%{tools: tools})]),
          open: true
        )

      assert html =~ "1 tool"
      assert html =~ "create_issue"
      assert html =~ "Opens an issue"
    end

    test "surfaces a failure and the login a server is waiting on" do
      servers = [
        mcp_server(%{name: "broken", status: :failed, error: "Executable not found: nope"}),
        mcp_server(%{name: "remote", status: :needs_auth, login_command: "eva mcp login remote"})
      ]

      html = render_component(&ChatComponents.mcp_panel/1, mcp: mcp_state(servers), open: true)

      assert html =~ "Executable not found: nope"
      assert html =~ "eva mcp login remote"
      assert html =~ "needs login"
    end

    test "shows config diagnostics and a hint when nothing is configured" do
      html =
        render_component(&ChatComponents.mcp_panel/1,
          mcp: mcp_state([], ["Cannot determine MCP server type for demo"]),
          open: true
        )

      assert html =~ "Cannot determine MCP server type for demo"
      assert html =~ "No MCP servers configured"
      assert html =~ "mcp.json"
    end

    test "says so when a connected server exposes nothing" do
      html =
        render_component(&ChatComponents.mcp_panel/1,
          mcp: mcp_state([mcp_server(%{})]),
          open: true
        )

      assert html =~ "No tools exposed."
    end
  end

  describe "mcp_panel/1 toggles" do
    defp panel(servers) do
      render_component(&ChatComponents.mcp_panel/1, mcp: mcp_state(servers), open: true)
    end

    test "a running server offers to be switched off" do
      html = panel([mcp_server(%{})])

      assert html =~ ~s|id="mcp-switch-github"|
      assert html =~ ~s|aria-checked="true"|
      # The click carries the state being asked for, not the current one.
      assert html =~ ~s|phx-value-enabled="false"|
      assert html =~ "Disable github"
    end

    test "a switched-off server offers to be switched back on" do
      html =
        panel([mcp_server(%{status: :disabled, enabled?: false, config_enabled: false})])

      assert html =~ ~s|aria-checked="false"|
      assert html =~ ~s|phx-value-enabled="true"|
      assert html =~ "Enable github"
      assert html =~ "off"
    end

    # Without this the toggle looks permanent, and the user has no way to know their next session
    # will start with the server back the way the file has it.
    test "a session override says so and offers to make it permanent" do
      html =
        panel([
          mcp_server(%{
            status: :disabled,
            enabled?: false,
            config_enabled: true,
            session_enabled: false,
            overridden?: true
          })
        ])

      assert html =~ "This session only"
      assert html =~ "config says on"
      assert html =~ ~s|id="mcp-persist-github"|
      # Persisting writes the state the session is actually in.
      assert html =~ ~s|phx-click="mcp_persist"|
    end

    test "a server following its config offers nothing to save" do
      refute panel([mcp_server(%{})]) =~ "mcp-persist-github"
    end

    test "an error from before a server was switched off is not shown as a fault" do
      html =
        panel([mcp_server(%{status: :disabled, enabled?: false, error: nil, tools: []})])

      refute html =~ "bg-red-950"
    end
  end

  describe "message/1 for MCP tool rows" do
    test "badges the row with the server the call went to" do
      item = EvaWeb.Sessions.Transcript.tool_started("c1", "mcp__github__create_issue", %{})

      html = render_component(&ChatComponents.message/1, item: item)

      assert html =~ "create_issue"
      assert html =~ "MCP server: github"
    end

    test "shows the latest progress line while the call runs" do
      item = EvaWeb.Sessions.Transcript.tool_started("c1", "mcp__x__y", %{}, "cloning repo")

      assert render_component(&ChatComponents.message/1, item: item) =~ "cloning repo"
    end

    test "drops progress once the call finishes" do
      finished =
        EvaWeb.Sessions.Transcript.tool_finished(
          "c1",
          "mcp__x__y",
          %{},
          %{content: [%Eva.Agent.Messages.TextContent{text: "done"}]},
          false
        )

      html = render_component(&ChatComponents.message/1, item: finished)

      assert html =~ "done"
      refute html =~ "cloning repo"
    end
  end

  describe "message/1 for user rows" do
    defp user_item(attrs \\ %{}) do
      "m0"
      |> EvaWeb.Sessions.Transcript.user_item(%Eva.Agent.Messages.UserMessage{content: "hello"})
      |> Map.merge(attrs)
    end

    test "offers no fork control until the message has an entry to fork at" do
      html = render_component(&ChatComponents.message/1, item: user_item())

      refute html =~ ~s(phx-click="fork")
    end

    test "forks at the entry the message was stored as" do
      html = render_component(&ChatComponents.message/1, item: user_item(%{entry_id: "e1"}))

      assert html =~ ~s(phx-click="fork")
      assert html =~ ~s(phx-value-entry="e1")
    end

    test "counts the forks taken from the message and links to each" do
      item =
        user_item(%{
          entry_id: "e1",
          forks: [
            %{session_id: "s1", title: "a better idea"},
            %{session_id: "s2", title: "another angle"}
          ]
        })

      html = render_component(&ChatComponents.message/1, item: item)

      assert html =~ "2 forks"
      assert html =~ ~s(href="/sessions/s1")
      assert html =~ "a better idea"
      assert html =~ ~s(href="/sessions/s2")
      assert html =~ "another angle"
    end

    test "counts a single fork in the singular" do
      item = user_item(%{entry_id: "e1", forks: [%{session_id: "s1", title: "a better idea"}]})

      assert render_component(&ChatComponents.message/1, item: item) =~ "1 fork"
    end

    test "offers to copy the bubble" do
      html = render_component(&ChatComponents.message/1, item: user_item())

      assert html =~ ~s(phx-hook="Copy")
      assert html =~ ~s(data-copy-from="m0-body")
      assert html =~ ~s(id="m0-body")
    end

    test "shows when the message was sent" do
      item = user_item(%{at: 1_785_176_488.134})

      html = render_component(&ChatComponents.message/1, item: item)

      assert html =~ ChatComponents.short_time(1_785_176_488.134)
      assert html =~ ~s(datetime="2026-07-27T18:21:28Z")
    end

    test "leaves the time out of a row that has not been stored yet" do
      refute render_component(&ChatComponents.message/1, item: user_item()) =~ "<time"
    end
  end

  describe "message/1 for assistant rows" do
    defp assistant_item(attrs \\ %{}) do
      message = %Eva.Agent.Messages.AssistantMessage{
        content: [%Eva.Agent.Messages.TextContent{text: "the answer"}]
      }

      "m1"
      |> EvaWeb.Sessions.Transcript.assistant_item(message)
      |> Map.merge(attrs)
    end

    test "offers to copy the prose, and marks which part of the row that is" do
      html = render_component(&ChatComponents.message/1, item: assistant_item())

      assert html =~ ~s(data-copy-from="m1-body")
      assert html =~ "data-copy-part"
    end

    test "shows when the reply came in" do
      html =
        render_component(&ChatComponents.message/1,
          item: assistant_item(%{at: 1_785_176_488.134})
        )

      assert html =~ ChatComponents.short_time(1_785_176_488.134)
    end

    # An empty row is the typing indicator; there is nothing to copy or date yet.
    test "leaves a row that has said nothing yet bare" do
      html = render_component(&ChatComponents.message/1, item: assistant_item(%{blocks: []}))

      refute html =~ ~s(phx-hook="Copy")
    end

    test "leaves a row that has only thought so far bare" do
      item = assistant_item(%{blocks: [{:thinking, "hmm"}]})

      refute render_component(&ChatComponents.message/1, item: item) =~ ~s(phx-hook="Copy")
    end
  end

  describe "short_time/1 and long_time/1" do
    test "gives the clock time on the day it happened" do
      {date, {hour, minute, _second}} = :calendar.local_time()
      at = :calendar.local_time_to_universal_time_dst({date, {hour, minute, 0}}) |> hd()
      seconds = :calendar.datetime_to_gregorian_seconds(at) - 62_167_219_200

      assert ChatComponents.short_time(seconds) =~ ~r/^\d{1,2}:\d{2} [ap]m$/
    end

    test "dates a row from another day" do
      assert ChatComponents.short_time(1_785_176_488.134) =~
               ~r/^[A-Z][a-z]{2} \d{1,2}, \d{1,2}:\d{2} [ap]m$/
    end

    test "spells the whole timestamp out for the tooltip" do
      assert ChatComponents.long_time(1_785_176_488.134) =~
               ~r/^\d{1,2} [A-Z][a-z]{2} 2026, \d{1,2}:\d{2}:\d{2} [ap]m$/
    end
  end
end
