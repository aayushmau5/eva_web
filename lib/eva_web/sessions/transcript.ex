defmodule EvaWeb.Sessions.Transcript do
  @moduledoc """
  Turns Eva messages into flat, renderable items for the chat stream.

  Two paths feed the same stream: replaying a stored transcript on mount, and applying live agent
  events as they arrive. They must produce the same shapes under the same ids, or a session looks
  different depending on whether you watched it happen or opened it later. Tool rows are keyed by
  `tool_call_id` precisely so a `ToolExecutionStart` and a persisted `ToolResultMessage` land on the
  same row.
  """

  alias Eva.Agent.Messages

  @type block :: {:text, String.t()} | {:thinking, String.t()}
  @type status :: :running | :ok | :error

  @type item :: %{
          id: String.t(),
          kind: :user | :assistant | :tool | :note,
          blocks: [block()],
          text: String.t(),
          name: String.t() | nil,
          args: map() | nil,
          status: status() | nil,
          error: String.t() | nil,
          patch: String.t() | nil
        }

  @base %{
    id: nil,
    kind: :note,
    blocks: [],
    text: "",
    name: nil,
    args: nil,
    status: nil,
    error: nil,
    patch: nil
  }

  @doc """
  Converts a stored transcript into stream items.

  Tool arguments live on the assistant's `ToolCall` blocks while results live on later
  `ToolResultMessage`s, so arguments are collected in a first pass and joined onto the tool rows.
  """
  @spec to_items([struct()]) :: [item()]
  def to_items(messages) do
    args_by_call_id = tool_call_args(messages)

    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, index} -> to_item(message, index, args_by_call_id) end)
  end

  @doc "Id for the nth message row. Tool rows use `tool_id/1` instead."
  @spec message_id(non_neg_integer()) :: String.t()
  def message_id(index), do: "m#{index}"

  @doc "Id for a tool row, stable across the start event, the end event and the stored result."
  @spec tool_id(String.t()) :: String.t()
  def tool_id(tool_call_id), do: "t#{tool_call_id}"

  @doc "Renders an assistant message — partial or final — into an item under an existing id."
  @spec assistant_item(String.t(), Messages.AssistantMessage.t()) :: item()
  def assistant_item(id, %Messages.AssistantMessage{} = message) do
    %{
      @base
      | id: id,
        kind: :assistant,
        blocks: blocks(message.content),
        text: Messages.AssistantMessage.text(message),
        error: error_message(message)
    }
  end

  @doc "Renders a user message into an item under an existing id."
  @spec user_item(String.t(), Messages.UserMessage.t()) :: item()
  def user_item(id, %Messages.UserMessage{} = message) do
    %{@base | id: id, kind: :user, text: Messages.UserMessage.text(message)}
  end

  @doc "A tool row that has started but not finished."
  @spec tool_started(String.t(), String.t(), map()) :: item()
  def tool_started(tool_call_id, tool_name, args) do
    %{
      @base
      | id: tool_id(tool_call_id),
        kind: :tool,
        name: tool_name,
        args: args,
        status: :running
    }
  end

  @doc "A finished tool row, from a `ToolExecutionEnd` event."
  @spec tool_finished(String.t(), String.t(), map(), struct(), boolean()) :: item()
  def tool_finished(tool_call_id, tool_name, args, result, is_error?) do
    details = Map.get(result, :details) || %{}

    %{
      @base
      | id: tool_id(tool_call_id),
        kind: :tool,
        name: tool_name,
        args: args,
        status: if(is_error?, do: :error, else: :ok),
        text: Messages.content_text(result.content),
        patch: Map.get(details, :patch) || details["patch"]
    }
  end

  @doc "A one-line summary of tool arguments for the collapsed row."
  @spec args_summary(map() | nil) :: String.t()
  def args_summary(args) when args in [nil, %{}], do: ""

  def args_summary(args) do
    args
    |> Enum.map(fn {key, value} -> "#{key}: #{inline(value)}" end)
    |> Enum.join("  ")
  end

  # -- Private --

  defp to_item(%Messages.UserMessage{} = message, index, _args) do
    [user_item(message_id(index), message)]
  end

  defp to_item(%Messages.AssistantMessage{} = message, index, _args) do
    # Tool calls are rendered as their own rows, keyed by tool_call_id, so they're dropped here.
    case assistant_item(message_id(index), message) do
      %{blocks: [], error: nil} -> []
      item -> [item]
    end
  end

  defp to_item(%Messages.ToolResultMessage{} = message, _index, args) do
    details = message.details || %{}

    [
      %{
        @base
        | id: tool_id(message.tool_call_id),
          kind: :tool,
          name: message.tool_name,
          args: Map.get(args, message.tool_call_id),
          status: if(message.is_error, do: :error, else: :ok),
          text: Messages.ToolResultMessage.text(message),
          patch: Map.get(details, :patch) || details["patch"]
      }
    ]
  end

  defp to_item(%Messages.BashExecutionMessage{} = message, index, _args) do
    [
      %{
        @base
        | id: message_id(index),
          kind: :tool,
          name: "bash",
          args: %{command: message.command},
          status: if(message.exit_code in [0, nil], do: :ok, else: :error),
          text: message.output || ""
      }
    ]
  end

  defp to_item(%Messages.CompactionSummaryMessage{} = message, index, _args) do
    [%{@base | id: message_id(index), kind: :note, text: "Compacted: #{message.summary}"}]
  end

  defp to_item(%Messages.BranchSummaryMessage{} = message, index, _args) do
    [%{@base | id: message_id(index), kind: :note, text: "Branch: #{message.summary}"}]
  end

  defp to_item(%Messages.CustomMessage{display: true} = message, index, _args) do
    [%{@base | id: message_id(index), kind: :note, text: Messages.CustomMessage.text(message)}]
  end

  defp to_item(_message, _index, _args), do: []

  defp tool_call_args(messages) do
    for %Messages.AssistantMessage{} = message <- messages,
        tool_call <- Messages.AssistantMessage.tool_calls(message),
        into: %{},
        do: {tool_call.id, tool_call.arguments}
  end

  defp blocks(content) do
    Enum.flat_map(content, fn
      %Messages.TextContent{text: ""} -> []
      %Messages.TextContent{text: text} -> [{:text, text}]
      %Messages.ThinkingContent{thinking: ""} -> []
      %Messages.ThinkingContent{thinking: thinking} -> [{:thinking, thinking}]
      _other -> []
    end)
  end

  defp error_message(%Messages.AssistantMessage{stop_reason: :error} = message) do
    message.error_message || "The model returned an error."
  end

  defp error_message(%Messages.AssistantMessage{stop_reason: :aborted}), do: "Cancelled."
  defp error_message(_message), do: nil

  defp inline(value) when is_binary(value) do
    value |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 80)
  end

  defp inline(value), do: value |> inspect() |> String.slice(0, 80)
end
