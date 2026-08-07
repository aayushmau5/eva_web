defmodule EvaWeb.Sessions.Transcript do
  @moduledoc """
  Turns Eva messages into flat, renderable items for the chat stream.

  Two paths feed the same stream: replaying a stored transcript on mount, and applying live agent
  events as they arrive. They must produce the same shapes under the same ids, or a session looks
  different depending on whether you watched it happen or opened it later. Tool rows are keyed by
  `tool_call_id` precisely so a `ToolExecutionStart` and a persisted `ToolResultMessage` land on the
  same row.
  """

  alias Eva.Core.Agent.Messages
  alias EvaWeb.Sessions.Ledger

  @type block :: {:text, String.t()} | {:thinking, String.t()}
  @type status :: :running | :ok | :error

  @type item :: %{
          id: String.t(),
          kind: :user | :assistant | :tool | :note,
          blocks: [block()],
          text: String.t(),
          name: String.t() | nil,
          server: String.t() | nil,
          args: map() | nil,
          status: status() | nil,
          error: String.t() | nil,
          patch: String.t() | nil,
          progress: String.t() | nil,
          at: float() | nil,
          entry_id: String.t() | nil,
          forks: [Ledger.fork()],
          streaming?: boolean(),
          origin: :agent | :user,
          private?: boolean(),
          level: :info | :warning | :error | nil,
          source: String.t() | nil
        }

  # `at`, `entry_id` and `forks` come from `EvaWeb.Sessions.Ledger` rather than from the message: a
  # message says nothing about the entry it was stored as, and its own timestamp is a compile-time
  # default. Rows with nothing to fork at, or that Eva has yet to store, keep the defaults.
  @base %{
    id: nil,
    kind: :note,
    blocks: [],
    text: "",
    name: nil,
    server: nil,
    args: nil,
    status: nil,
    error: nil,
    patch: nil,
    progress: nil,
    at: nil,
    entry_id: nil,
    forks: [],
    # Still arriving. Only ever true for the assistant row currently being written, and only from a
    # live event — everything read back from storage has finished.
    streaming?: false,
    # Who ran it. A bash row the user typed themselves and one the model called look the same
    # otherwise, and which of the two it was is most of what the row means.
    origin: :agent,
    private?: false,
    # Notes are otherwise all alike — a compaction summary reads the same as an extension shouting
    # about a failure. These two are what tell them apart, and both are nil for Eva's own notes.
    level: nil,
    source: nil
  }

  @doc """
  Converts a stored transcript into stream items.

  Tool arguments live on the assistant's `ToolCall` blocks while results live on later
  `ToolResultMessage`s, so arguments are collected in a first pass and joined onto the tool rows.

  `ledger` supplies what the messages themselves can't say — when each was written, and what has
  been forked from it. Rows it doesn't reach simply go without.
  """
  @spec to_items([struct()], Ledger.t()) :: [item()]
  def to_items(messages, ledger \\ Ledger.empty()) do
    args_by_call_id = tool_call_args(messages)

    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, index} ->
      message
      |> to_item(index, args_by_call_id)
      |> Enum.map(&from_ledger(&1, ledger, index))
    end)
  end

  @doc "Now, in the float unix-seconds Eva stamps its entries with."
  @spec now() :: float()
  def now, do: System.os_time(:millisecond) / 1000

  @doc "Id for the nth message row. Tool rows use `tool_id/1` instead."
  @spec message_id(non_neg_integer()) :: String.t()
  def message_id(index), do: "m#{index}"

  @doc "Id for a tool row, stable across the start event, the end event and the stored result."
  @spec tool_id(String.t()) :: String.t()
  def tool_id(tool_call_id), do: "t#{tool_call_id}"

  @doc """
  Renders an assistant message — partial or final — into an item under an existing id.

  `at` is carried by the caller across a message's updates: a row is stamped when it starts, and
  every delta after that rebuilds it whole.

  `streaming?` marks the row as still being written, which is a live event's to say — a message
  read back from storage has finished by definition.
  """
  @spec assistant_item(String.t(), Messages.AssistantMessage.t(), float() | nil, boolean()) ::
          item()
  def assistant_item(id, %Messages.AssistantMessage{} = message, at \\ nil, streaming? \\ false) do
    %{
      @base
      | id: id,
        kind: :assistant,
        blocks: blocks(message.content),
        text: Messages.AssistantMessage.text(message),
        error: error_message(message),
        at: at,
        streaming?: streaming?
    }
  end

  @doc "Renders a user message into an item under an existing id."
  @spec user_item(String.t(), Messages.UserMessage.t(), float() | nil) :: item()
  def user_item(id, %Messages.UserMessage{} = message, at \\ nil) do
    %{@base | id: id, kind: :user, text: Messages.UserMessage.text(message), at: at}
  end

  @doc """
  Renders a custom message — an extension talking to the user rather than to the model.

  Eva emits these for a `/command`'s reply, for input a hook answered itself, for
  `API.notify/3` and for `API.send_custom_message/4`. None of them are part of the
  conversation the model sees and most are never written to disk, so they exist only as the
  row this builds.

  `custom_type` is carried through as `name` because it is the extension's own label for what
  it just said, and `send_custom_message/4` lets an extension choose it.
  """
  @spec custom_item(String.t(), Messages.CustomMessage.t(), float() | nil) :: item()
  def custom_item(id, %Messages.CustomMessage{} = message, at \\ nil) do
    details = message.details || %{}

    %{
      @base
      | id: id,
        kind: :note,
        name: message.custom_type,
        text: Messages.CustomMessage.text(message),
        level: level(details["level"]),
        source: details["extension"],
        at: at
    }
  end

  @doc """
  A tool row that has started but not finished.

  `progress` is the latest line an MCP server reported through `notifications/progress`. Each one
  replaces the last rather than appending, because a progress notification describes where the call
  is now, not what it has done so far.
  """
  @spec tool_started(String.t(), String.t(), map(), String.t() | nil) :: item()
  def tool_started(tool_call_id, tool_name, args, progress \\ nil) do
    %{
      @base
      | id: tool_id(tool_call_id),
        kind: :tool,
        args: args,
        status: :running,
        progress: progress
    }
    |> put_tool_name(tool_name)
  end

  @doc "A finished tool row, from a `ToolExecutionEnd` event."
  @spec tool_finished(String.t(), String.t(), map(), struct(), boolean()) :: item()
  def tool_finished(tool_call_id, tool_name, args, result, is_error?) do
    details = Map.get(result, :details) || %{}

    %{
      @base
      | id: tool_id(tool_call_id),
        kind: :tool,
        args: args,
        status: if(is_error?, do: :error, else: :ok),
        text: Messages.content_text(result.content),
        patch: Map.get(details, :patch) || details["patch"]
    }
    |> put_tool_name(tool_name)
  end

  @doc """
  A row for a command the user ran themselves, still going.

  Eva only reports a `!` command once it has finished — it is a blocking call, not a stream — so
  this is what stands in for it meanwhile. It shares the shape of a tool row because that is what
  it becomes: `bash_finished/2` replaces it under the same id.
  """
  @spec bash_started(String.t(), String.t(), boolean() | nil) :: item()
  def bash_started(id, command, private?) do
    %{
      @base
      | id: id,
        kind: :tool,
        name: "bash",
        args: %{command: command},
        status: :running,
        at: now(),
        origin: :user,
        # Eva reads the flag off the caller's options, which are absent as often as they are false.
        private?: private? == true
    }
  end

  @doc "A finished bash row, replayed or live. `cancelled` reads as a failure, because it is one."
  @spec bash_finished(String.t(), Messages.BashExecutionMessage.t()) :: item()
  def bash_finished(id, %Messages.BashExecutionMessage{} = message) do
    ok? = message.exit_code in [0, nil] and not message.cancelled

    %{
      @base
      | id: id,
        kind: :tool,
        name: "bash",
        args: %{command: message.command},
        status: if(ok?, do: :ok, else: :error),
        text: message.output || "",
        origin: :user,
        private?: message.exclude_from_context
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

  # Forks only ever hang off user messages, so only those rows carry the entry to fork at — every
  # other row would show a control Eva would refuse.
  defp from_ledger(item, ledger, index) do
    case Ledger.row(ledger, index) do
      nil ->
        item

      %{fork_point: fork_point} = row when item.kind == :user ->
        %{item | at: row.at, entry_id: fork_point, forks: Ledger.forks_at(ledger, fork_point)}

      row ->
        %{item | at: row.at}
    end
  end

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
          args: Map.get(args, message.tool_call_id),
          status: if(message.is_error, do: :error, else: :ok),
          text: Messages.ToolResultMessage.text(message),
          patch: Map.get(details, :patch) || details["patch"]
      }
      |> put_tool_name(message.tool_name)
    ]
  end

  defp to_item(%Messages.BashExecutionMessage{} = message, index, _args) do
    [bash_finished(message_id(index), message)]
  end

  defp to_item(%Messages.CompactionSummaryMessage{} = message, index, _args) do
    [%{@base | id: message_id(index), kind: :note, text: "Compacted: #{message.summary}"}]
  end

  defp to_item(%Messages.BranchSummaryMessage{} = message, index, _args) do
    [%{@base | id: message_id(index), kind: :note, text: "Branch: #{message.summary}"}]
  end

  defp to_item(%Messages.CustomMessage{display: true} = message, index, _args) do
    [custom_item(message_id(index), message)]
  end

  defp to_item(_message, _index, _args), do: []

  # MCP tools reach the model as `mcp__<server>__<tool>`, which is what gets persisted. Splitting
  # it here means a replayed row and a live one are attributed identically, with no lookup against
  # a server that may not even be connected any more.
  #
  # The prefix is the MCP extension's own doing — `Eva.Extension.MCP.ToolAdapter` builds it, on a
  # node this VM never loads code from. Reading it off the name is all a transcript can do, and it
  # is enough: a persisted row has nothing but the name either.
  defp put_tool_name(item, tool_name) do
    case mcp_source(tool_name) do
      {server, tool} -> %{item | name: tool, server: server}
      nil -> %{item | name: tool_name}
    end
  end

  defp mcp_source("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {server, tool}
      _other -> nil
    end
  end

  defp mcp_source(_name), do: nil

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

  # `API.notify/3` is the only thing that sets this, so anything else — a command's reply, a
  # message an extension composed itself — is ordinary and reads as such.
  defp level("warning"), do: :warning
  defp level("error"), do: :error
  defp level("info"), do: :info
  defp level(_other), do: nil

  defp inline(value) when is_binary(value) do
    value
    |> String.split("\n", parts: 2)
    |> List.first()
    |> then(fn
      s when byte_size(s) <= 80 -> s
      s -> String.slice(s, 0, 80) <> "…"
    end)
  end

  defp inline(value) do
    value
    |> inspect()
    |> then(fn
      s when byte_size(s) <= 80 -> s
      s -> String.slice(s, 0, 80) <> "…"
    end)
  end
end
