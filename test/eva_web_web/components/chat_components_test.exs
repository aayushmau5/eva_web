defmodule EvaWebWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvaWebWeb.ChatComponents

  defp render(text), do: text |> ChatComponents.markdown() |> Phoenix.HTML.safe_to_string()

  defp extension(attrs \\ %{}) do
    Map.merge(
      %{
        name: "memory",
        path: "/home/u/.eva/extensions/memory.exs",
        scope: :global,
        node: nil,
        module: Eva.Extension.Memory,
        status: :running,
        loaded?: true,
        tool_count: 1,
        commands: [],
        hooks: [],
        event_classes: []
      },
      attrs
    )
  end

  # An extension that announced itself from its own node: no file here, no module loaded in this
  # VM, and its lifetime is the node's rather than the session's.
  defp node_extension(attrs \\ %{}) do
    extension(
      Map.merge(
        %{
          name: "mcp",
          path: nil,
          scope: :node,
          node: :"eva_ext_mcp@127.0.0.1",
          module: nil,
          tool_count: 12
        },
        attrs
      )
    )
  end

  defp extensions_state(extensions, opts \\ []) do
    %{
      extensions: extensions,
      diagnostics: Keyword.get(opts, :diagnostics, []),
      pending: Keyword.get(opts, :pending, [])
    }
  end

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

  describe "extensions_indicator/1" do
    test "counts what loaded against what was discovered" do
      html =
        render_component(&ChatComponents.extensions_indicator/1,
          extensions: extensions_state([extension(), extension(%{name: "off", loaded?: false})])
        )

      assert html =~ "EXT"
      assert html =~ "1/2"
    end

    test "stays out of the way for a session with no extensions" do
      html =
        render_component(&ChatComponents.extensions_indicator/1, extensions: extensions_state([]))

      refute html =~ "extensions-toggle"
    end

    # Both of these are states where the panel is the only thing on screen with anything to say.
    test "shows up for a load failure even with nothing loaded" do
      html =
        render_component(&ChatComponents.extensions_indicator/1,
          extensions: extensions_state([], diagnostics: ["memory.exs failed to compile"])
        )

      assert html =~ "extensions-toggle"
      assert html =~ "bg-red-500"
    end

    test "shows a directory waiting for approval in amber rather than red" do
      html =
        render_component(&ChatComponents.extensions_indicator/1,
          extensions:
            extensions_state([],
              pending: ["/repo/.eva/extensions"],
              diagnostics: ["/repo/.eva/extensions has extensions that have not been approved"]
            )
        )

      assert html =~ "extensions-toggle"
      assert html =~ "bg-amber-500"
      refute html =~ "bg-red-500"
    end
  end

  describe "extensions_panel/1" do
    defp panel(extensions, opts \\ []) do
      render_component(&ChatComponents.extensions_panel/1,
        extensions: extensions,
        open: true,
        running: Keyword.get(opts, :running, false)
      )
    end

    test "renders nothing while closed" do
      html =
        render_component(&ChatComponents.extensions_panel/1,
          extensions: extensions_state([extension()]),
          open: false
        )

      refute html =~ "extensions-panel"
    end

    test "lists an extension with where it came from and what it contributes" do
      html =
        panel(
          extensions_state([
            extension(%{tool_count: 2, hooks: [:context, :tool_call], event_classes: [:agent]})
          ])
        )

      assert html =~ "memory"
      assert html =~ "/home/u/.eva/extensions/memory.exs"
      assert html =~ "global"
      assert html =~ "running"
      assert html =~ "2 tools"
      assert html =~ "context"
      assert html =~ "agent events"
    end

    # A switched-off extension has no spec to describe it, so the row is all that is left to switch
    # it back on with.
    test "keeps a row for a switched-off extension" do
      html = panel(extensions_state([extension(%{status: :off, loaded?: false, tool_count: 0})]))

      assert html =~ "extension-switch-memory"
      assert html =~ "Switch on"
      assert html =~ "off"
    end

    test "says which node an extension is running on when there is no file to name" do
      html = panel(extensions_state([node_extension()]))

      assert html =~ "mcp"
      assert html =~ "node"
      assert html =~ "eva_ext_mcp@127.0.0.1"
    end

    # Eva would take it out readily enough; putting it back means finding it on disk, and there is
    # nothing there to find.
    test "offers no switch for an extension owned by another node" do
      html = panel(extensions_state([node_extension()]))

      assert html =~ "mix eva.ext.stop mcp"
      assert html =~ "disabled"
    end

    test "hints at where extensions go when there are none" do
      html = panel(extensions_state([]))

      assert html =~ "No extensions"
      assert html =~ "~/.eva/extensions/"
    end

    test "shows what failed to load" do
      html = panel(extensions_state([], diagnostics: ["memory.exs failed to compile: oops"]))

      assert html =~ "failed to compile: oops"
    end

    test "reload waits for the turn to finish" do
      assert panel(extensions_state([extension()]), running: true) =~
               "Eva is working — reload when the turn ends"
    end
  end

  describe "extension_trust/1" do
    test "names the directory and asks before loading anything from it" do
      html =
        render_component(&ChatComponents.extension_trust/1, pending: ["/repo/.eva/extensions"])

      assert html =~ "Waiting for approval"
      assert html =~ "/repo/.eva/extensions"
      assert html =~ "extensions-trust-approve"
      assert html =~ "Approve and load"
    end

    test "renders nothing when no directory is waiting" do
      refute render_component(&ChatComponents.extension_trust/1, pending: []) =~
               "extensions-trust"
    end

    # Approving is a reload, and Eva refuses a reload mid-turn.
    test "approving waits for the turn to finish" do
      html =
        render_component(&ChatComponents.extension_trust/1,
          pending: ["/repo/.eva/extensions"],
          running: true
        )

      assert html =~ "waits for the turn to end"
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
          %{content: [%Eva.Core.Agent.Messages.TextContent{text: "done"}]},
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
      |> EvaWeb.Sessions.Transcript.user_item(%Eva.Core.Agent.Messages.UserMessage{
        content: "hello"
      })
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
      message = %Eva.Core.Agent.Messages.AssistantMessage{
        content: [%Eva.Core.Agent.Messages.TextContent{text: "the answer"}]
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

  describe "composer/1 modes" do
    defp composer(mode, running \\ false) do
      render_component(&ChatComponents.composer/1, mode: mode, running: running, disabled: false)
    end

    test "starts in prompt mode and says how to leave it" do
      html = composer(:prompt)

      assert html =~ "prompt"
      assert html =~ "! for a command"
      assert html =~ ~s(data-mode="prompt")
      assert html =~ "Send a message…"
    end

    # The hook reads the mode off this attribute to decide whether a leading `!` is a character or
    # a switch, so it is load-bearing rather than decorative.
    test "publishes the mode to the input the hook is bound to" do
      assert composer(:command) =~ ~s(data-mode="command")
      assert composer(:private_command) =~ ~s(data-mode="private_command")
    end

    test "a command mode says what will happen to the command" do
      assert composer(:command) =~ "Run a shell command…"
      assert composer(:private_command) =~ "not sent to the model"
    end

    # Eva refuses to run one mid-turn, so the composer should not invite it.
    test "says why a command will not run while the agent works" do
      assert composer(:command, true) =~ "Eva is working"
    end

    test "offers the mode itself as a control" do
      assert composer(:prompt) =~ ~s(phx-click="cycle_mode")
    end

    test "a command in flight can be stopped instead of sent to" do
      html =
        render_component(&ChatComponents.composer/1,
          mode: :prompt,
          running: false,
          disabled: false,
          command_running: true
        )

      assert html =~ ~s(phx-click="cancel_bash")
      assert html =~ "Stop the command"
      refute html =~ ~s(id="send-button")
    end

    # Stopping the agent and stopping a command are different buttons doing different things, and
    # Eva won't run a command mid-turn, so they never appear together.
    test "stopping the agent is a separate control from stopping a command" do
      html = composer(:prompt, true)

      assert html =~ ~s(id="cancel-button")
      refute html =~ ~s(phx-click="cancel_bash")
    end
  end

  describe "message/1 for bash rows" do
    defp bash_row(attrs) do
      message =
        struct!(
          %Eva.Core.Agent.Messages.BashExecutionMessage{command: "ls", output: "a.ex"},
          attrs
        )

      item = EvaWeb.Sessions.Transcript.bash_finished("m2", message)

      render_component(&ChatComponents.message/1, item: item)
    end

    test "marks a command the user ran and opens it on its output" do
      html = bash_row(exit_code: 0)

      assert html =~ ~s(title="You ran this")
      assert html =~ "<details"
      assert html =~ "open"
    end

    test "marks a command the model never sees" do
      html = bash_row(exclude_from_context: true)

      assert html =~ "private"
      assert html =~ ~s(title="Kept out of the model's context")
    end

    test "leaves a run that went to the model unmarked" do
      refute bash_row(exclude_from_context: false) =~ "private"
    end

    # The model's own bash calls arrive as tool rows and must stay collapsed and unbadged.
    test "an agent tool row is neither attributed nor opened" do
      item = EvaWeb.Sessions.Transcript.tool_started("c1", "bash", %{"command" => "ls"})
      html = render_component(&ChatComponents.message/1, item: item)

      refute html =~ "You ran this"
      refute html =~ "<details open"
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
