defmodule EvaWeb.Sessions.MCP do
  @moduledoc """
  A session's view of its MCP servers, for the panel and its toggles.

  Eva's `Eva.MCP.SessionServers` is the source of truth: it owns the config, the client lifecycle
  and which servers this session is actually running, and `list/1` hands that out in the shape a
  frontend needs. This module does not duplicate any of it — it re-reads that list whenever
  something happens and decorates each entry with the two things it doesn't carry:

    * the command or URL behind a server, read once from the config, which is how you tell two
      `npx` servers apart at a glance
    * the version handshake, the error text and any login command — facts that only exist on the
      wire, and only ever reach a subscriber as events

  It also derives what a toggle needs to say: whether a server is running because of the config
  file or because this session overrode it.
  """

  alias Eva.Coding.Resources
  alias Eva.MCP.Client
  alias Eva.MCP.Config
  alias Eva.MCP.Events
  alias Eva.MCP.SessionServers

  @type status :: :disabled | :connecting | :connected | :needs_auth | :failed

  @typedoc """
  One server as the panel renders it.

  `enabled?` is the effective answer. `config_enabled` and `session_enabled` are what produced it,
  which is what lets the UI say *which* of the two a toggle would be changing.
  """
  @type server :: %{
          name: String.t(),
          scope: :global | String.t(),
          transport: :stdio | :http,
          target: String.t(),
          status: status(),
          enabled?: boolean(),
          config_enabled: boolean(),
          session_enabled: boolean() | nil,
          overridden?: boolean(),
          tools: [Events.tool()],
          server_version: String.t() | nil,
          protocol_version: String.t() | nil,
          error: String.t() | nil,
          login_command: String.t() | nil
        }

  @type t :: %{servers: [server()], diagnostics: [String.t()], meta: map()}

  @empty_meta %{server_version: nil, protocol_version: nil, error: nil, login_command: nil}

  @doc "An empty state, for a view with no session open."
  @spec empty() :: t()
  def empty, do: %{servers: [], diagnostics: [], meta: %{}}

  @doc """
  Builds the initial state for a session's `cwd` and its server list.

  The config is read here only for the parts that never change at runtime — a server's command or
  URL, and the parse diagnostics Eva's session drops. Anything live comes from `infos`.

  A client that connected before this session existed will never re-announce itself, so its
  handshake is taken from `Eva.MCP.Client.snapshot/1` rather than waited for.
  """
  @spec new(String.t(), [SessionServers.server_info()]) :: t()
  def new(cwd, infos) do
    {configs, diagnostics} = Config.parse(%Resources{cwd: cwd})

    meta = Map.new(configs, &{&1.name, catch_up(&1)})

    %{
      servers: [],
      diagnostics: Enum.map(diagnostics, &format_diagnostic/1),
      meta: meta
    }
    |> refresh(infos)
  end

  @doc "Rebuilds the rendered list from a fresh `SessionServers.list/1`."
  @spec refresh(t(), [SessionServers.server_info()]) :: t()
  def refresh(state, infos) do
    %{state | servers: Enum.map(infos, &decorate(&1, meta_for(state, &1.name)))}
  end

  @doc "True for any struct this module knows how to fold in."
  @spec event?(term()) :: boolean()
  def event?(%{__struct__: module}), do: module in Events.modules()
  def event?(_other), do: false

  @doc """
  Folds an MCP event into the wire-level facts the server list doesn't carry.

  Eva already routes these into its own snapshots, so status and tools are left alone here —
  re-reading `list/1` is what picks those up, and second-guessing it is how the two disagree.
  """
  @spec apply_event(t(), struct()) :: t()
  def apply_event(%{meta: meta} = state, %{server_name: name} = event) do
    case changes_for(event) do
      nil ->
        state

      changes ->
        updated = Map.merge(meta_for(state, name), changes)
        %{state | meta: Map.put(meta, name, updated)}
    end
  end

  def apply_event(state, _event), do: state

  @doc "True when the session has any MCP server at all, switched on or not."
  @spec any?(t()) :: boolean()
  def any?(%{servers: servers}), do: servers != []

  @doc """
  How many servers are connected, over how many are switched on.

  Counting the switched-off ones in the denominator would leave the header reading 2/3 forever
  after a deliberate choice, which is indistinguishable from a server that can't connect.
  """
  @spec connected(t()) :: {non_neg_integer(), non_neg_integer()}
  def connected(%{servers: servers}) do
    enabled = Enum.filter(servers, & &1.enabled?)
    {Enum.count(enabled, &(&1.status == :connected)), length(enabled)}
  end

  @doc """
  Servers that need the user's attention.

  A server the user switched off is not a problem to report — only one that was meant to be
  running and isn't.
  """
  @spec unhealthy(t()) :: [server()]
  def unhealthy(%{servers: servers}) do
    Enum.filter(servers, &(&1.status in [:failed, :needs_auth]))
  end

  @doc "Total number of tools exposed to the model across every running server."
  @spec tool_count(t()) :: non_neg_integer()
  def tool_count(%{servers: servers}), do: servers |> Enum.map(&length(&1.tools)) |> Enum.sum()

  @doc """
  Splits a model-facing tool name back into `{server, tool}`.

  `Eva.MCP.ToolAdapter` builds these as `mcp__<server>__<tool>`, so the prefix alone is a reliable
  "this call went through MCP" marker even for the long names it truncates and hashes.
  """
  @spec source(String.t() | nil) :: {String.t(), String.t()} | nil
  def source("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {server, tool}
      _other -> nil
    end
  end

  def source(_name), do: nil

  @doc "Human label for where a server was configured."
  @spec scope_label(:global | String.t()) :: String.t()
  def scope_label(:global), do: "global"
  def scope_label(_cwd), do: "project"

  # -- Private --

  defp decorate(info, meta) do
    %{
      name: info.name,
      scope: info.scope_dir,
      transport: info.type,
      target: Map.get(meta, :target, ""),
      status: info.status,
      enabled?: info.status != :disabled,
      config_enabled: info.config_enabled,
      session_enabled: info.session_enabled,
      overridden?: overridden?(info),
      tools: info.tools,
      server_version: meta.server_version,
      protocol_version: meta.protocol_version,
      # A server that is switched off cannot be failing at anything, and showing the error it
      # left behind makes a deliberate choice look like a fault.
      error: if(info.status == :disabled, do: nil, else: meta.error),
      login_command: meta.login_command
    }
  end

  # `nil` means the session never touched it, so the file is having its way either way.
  defp overridden?(%{session_enabled: nil}), do: false
  defp overridden?(info), do: info.session_enabled != info.config_enabled

  defp meta_for(%{meta: meta}, name), do: Map.get(meta, name, @empty_meta)

  # A client wedged mid-handshake would otherwise take the caller down with it — `snapshot/1` is
  # answered from state and can't block on the wire, but a client that has crashed and not yet
  # restarted can still make this exit.
  defp catch_up(config) do
    meta = Map.put(@empty_meta, :target, target(config))

    case Client.whereis(config) do
      nil -> meta
      pid -> Map.merge(meta, Map.take(Client.snapshot(pid), [:server_version, :protocol_version]))
    end
  catch
    :exit, _reason -> Map.put(@empty_meta, :target, target(config))
  end

  defp target(%Config{type: :stdio, config: %Config.Stdio{} = stdio}) do
    Enum.join([stdio.command | stdio.args || []], " ")
  end

  defp target(%Config{type: :http, config: %Config.Http{url: url}}), do: url || ""

  defp changes_for(%Events.ServerConnected{} = event) do
    %{
      server_version: event.server_version,
      protocol_version: event.protocol_version,
      error: nil,
      login_command: nil
    }
  end

  defp changes_for(%Events.ServerDisconnected{reason: reason}) do
    %{error: "Connection lost (#{reason})"}
  end

  defp changes_for(%Events.ServerError{error: error}), do: %{error: error}

  defp changes_for(%Events.AuthRequired{login_command: command}) do
    %{login_command: command}
  end

  # Everything else — logs, resource and prompt notifications — is either already in Eva's
  # snapshot or says nothing the panel shows.
  defp changes_for(_event), do: nil

  defp format_diagnostic(diagnostic) when is_binary(diagnostic), do: diagnostic
  defp format_diagnostic(%{__struct__: _} = error), do: Exception.message(error)
  defp format_diagnostic(diagnostic), do: inspect(diagnostic)
end
