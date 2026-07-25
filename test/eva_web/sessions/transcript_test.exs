defmodule EvaWeb.Sessions.TranscriptTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.Messages
  alias EvaWeb.Sessions.Transcript

  defp text(content), do: %Messages.TextContent{text: content}
  defp thinking(content), do: %Messages.ThinkingContent{thinking: content}

  defp tool_call(id, name, args),
    do: %Messages.ToolCall{id: id, name: name, arguments: args}

  describe "to_items/1" do
    test "renders a user message" do
      items = Transcript.to_items([%Messages.UserMessage{content: "hello"}])

      assert [%{id: "m0", kind: :user, text: "hello"}] = items
    end

    test "keeps assistant text and thinking blocks in order and drops tool calls" do
      message = %Messages.AssistantMessage{
        content: [thinking("hmm"), text("hi"), tool_call("c1", "read", %{})]
      }

      assert [item] = Transcript.to_items([message])
      assert item.kind == :assistant
      assert item.blocks == [{:thinking, "hmm"}, {:text, "hi"}]
    end

    test "surfaces an errored assistant message" do
      message = %Messages.AssistantMessage{stop_reason: :error, error_message: "boom"}

      assert [%{kind: :assistant, error: "boom"}] = Transcript.to_items([message])
    end

    test "drops an assistant message that carries nothing renderable" do
      message = %Messages.AssistantMessage{content: [tool_call("c1", "read", %{})]}

      assert Transcript.to_items([message]) == []
    end

    test "joins a tool result back onto the arguments of its originating call" do
      messages = [
        %Messages.AssistantMessage{content: [tool_call("call_1", "read", %{"path" => "a.ex"})]},
        %Messages.ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "read",
          content: [text("file body")]
        }
      ]

      assert [item] = Transcript.to_items(messages)
      assert item.kind == :tool
      assert item.name == "read"
      assert item.args == %{"path" => "a.ex"}
      assert item.text == "file body"
      assert item.status == :ok
    end

    test "marks a failed tool result" do
      messages = [
        %Messages.ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "bash",
          is_error: true,
          content: [text("nope")]
        }
      ]

      assert [%{status: :error}] = Transcript.to_items(messages)
    end

    # The stream is keyed by item id, so a replayed tool row and a live one have to collide
    # deliberately — otherwise reopening a session renders it differently than watching it run.
    test "a replayed tool row lands on the same id as the live one" do
      replayed =
        Transcript.to_items([
          %Messages.ToolResultMessage{
            tool_call_id: "call_1",
            tool_name: "read",
            content: [text("body")]
          }
        ])

      live = Transcript.tool_started("call_1", "read", %{})

      finished =
        Transcript.tool_finished("call_1", "read", %{}, %{content: [text("body")]}, false)

      assert [%{id: id}] = replayed
      assert live.id == id
      assert finished.id == id
    end

    test "numbers message ids by transcript position" do
      messages = [
        %Messages.UserMessage{content: "one"},
        %Messages.AssistantMessage{content: [text("two")]},
        %Messages.UserMessage{content: "three"}
      ]

      assert ["m0", "m1", "m2"] = Enum.map(Transcript.to_items(messages), & &1.id)
    end
  end

  describe "assistant_item/2" do
    test "renders a partial message under an existing id" do
      partial = %Messages.AssistantMessage{content: [text("strea")]}

      assert %{id: "m7", kind: :assistant, blocks: [{:text, "strea"}]} =
               Transcript.assistant_item("m7", partial)
    end
  end

  describe "args_summary/1" do
    test "is blank when there is nothing to show" do
      assert Transcript.args_summary(nil) == ""
      assert Transcript.args_summary(%{}) == ""
    end

    test "collapses arguments onto one line" do
      summary = Transcript.args_summary(%{"path" => "lib/a.ex\nsecond line"})

      assert summary == "path: lib/a.ex"
    end
  end
end
