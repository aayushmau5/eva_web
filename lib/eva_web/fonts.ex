defmodule EvaWeb.Fonts do
  @moduledoc """
  The font families installed on the machine Eva is running on.

  This app runs on the user's own machine, so the honest source for "what fonts do I have" is the
  system itself rather than a hardcoded list or a webfont CDN. Enumeration goes through
  `fontconfig`, which knows about every font the OS has registered and can be asked directly for
  the monospaced ones — a distinction there is no way to make from a font's name.

  `fc-list` is not part of a stock macOS, so a machine without it falls back to the families that
  ship with the major desktops. The picker then still works; it just offers fewer choices.
  """

  require Logger

  @cache_key {__MODULE__, :families}
  @timeout_ms 5_000

  # Families that exist on a stock install of each major desktop. Ordered so the first entry that
  # a machine actually has is a reasonable default to look at.
  @fallback_ui [
    "SF Pro Text",
    "Helvetica Neue",
    "Segoe UI",
    "Inter",
    "Roboto",
    "Noto Sans",
    "DejaVu Sans",
    "Arial",
    "Verdana",
    "Georgia",
    "Times New Roman"
  ]

  @fallback_mono [
    "SF Mono",
    "Menlo",
    "Monaco",
    "Consolas",
    "Cascadia Mono",
    "JetBrains Mono",
    "Fira Code",
    "Source Code Pro",
    "DejaVu Sans Mono",
    "Liberation Mono",
    "Courier New"
  ]

  @type families :: %{ui: [String.t()], mono: [String.t()]}

  @doc """
  Every font family on this machine, split into all families and the monospaced ones.

  Cached after the first call — shelling out costs about a second, and the answer only changes
  when the user installs a font. `refresh/0` is the way to pick those up.
  """
  @spec list() :: families()
  def list do
    case :persistent_term.get(@cache_key, nil) do
      nil -> refresh()
      families -> families
    end
  end

  @doc "Re-reads the system font list, replacing the cache."
  @spec refresh() :: families()
  def refresh do
    families = %{ui: query(:all), mono: query(:mono)}
    :persistent_term.put(@cache_key, families)
    families
  end

  @doc """
  True when `family` is a font this machine actually has.

  Every user-supplied family is checked against this before it reaches a stylesheet, which is what
  keeps a font name from being a CSS injection.
  """
  @spec known?(String.t() | nil) :: boolean()
  def known?(nil), do: false

  def known?(family) when is_binary(family) do
    %{ui: ui, mono: mono} = list()
    family in ui or family in mono
  end

  def known?(_family), do: false

  # -- Private --

  defp query(kind) do
    case fc_list(kind) do
      {:ok, []} -> fallback(kind)
      {:ok, families} -> families
      :error -> fallback(kind)
    end
  end

  # `:spacing=100` is fontconfig's own monospace flag, which beats guessing from names — plenty of
  # monospaced faces don't say "Mono", and plenty of proportional ones do.
  defp fc_list(kind) do
    pattern = if kind == :mono, do: [":spacing=100"], else: []

    with path when is_binary(path) <- System.find_executable("fc-list"),
         {output, 0} <- cmd(path, pattern ++ ["--format", "%{family[0]}\n"]) do
      {:ok, parse(output)}
    else
      _other -> :error
    end
  end

  # A hung font cache must not hang the LiveView that asked, so the port is killed rather than
  # waited on. `Task` gives us a timeout that `System.cmd/3` does not have.
  defp cmd(path, args) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _other ->
        Logger.warning("EvaWeb.Fonts: fc-list timed out")
        :timeout
    end
  end

  # Families whose name starts with a dot are the OS's internal faces — fallback stacks, UI
  # variants the user is not meant to select — and fontconfig lists them alongside the real ones.
  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ".")))
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  defp fallback(:mono), do: @fallback_mono
  defp fallback(:all), do: Enum.sort_by(@fallback_ui ++ @fallback_mono, &String.downcase/1)
end
