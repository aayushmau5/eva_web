defmodule EvaWeb.Settings do
  @moduledoc """
  User preferences for the web UI, stored alongside Eva's own state in `~/.eva/`.

  Kept on the server rather than in the browser deliberately: settings picked here are rendered
  into the first response, so a reload never flashes the default font before a client-side script
  gets a chance to correct it, and the choice follows the user between browsers on the machine
  they're running Eva on.

  Unknown keys in the file are preserved on write, so a newer Eva writing settings this version
  doesn't understand won't have them stripped by a downgrade.
  """

  require Logger

  alias Eva.Coding.Paths
  alias EvaWeb.Fonts

  @filename "web.json"

  @default_scale 100

  @doc """
  The font sizes offered, as a percentage of the design's own.

  A fixed set rather than a free number: the scale multiplies a type ramp that the layout is built
  around, and arbitrary values are how you end up with a sidebar that no longer fits its labels.
  """
  @scales [80, 90, 100, 110, 125, 150]
  @spec scales() :: [pos_integer()]
  def scales, do: @scales

  @type key :: :ui_font | :mono_font | :font_scale
  @type t :: %{ui_font: String.t() | nil, mono_font: String.t() | nil, font_scale: pos_integer()}

  @doc "Current settings. Falls back to defaults for anything missing or no longer installed."
  @spec get() :: t()
  def get do
    stored = read()

    %{
      ui_font: font(stored["ui_font"]),
      mono_font: font(stored["mono_font"]),
      font_scale: scale(stored["font_scale"])
    }
  end

  @doc """
  Writes one setting and returns the settings as they now stand.

  A value the machine can't honour — a font it doesn't have, a scale that isn't offered — is
  rejected rather than stored, which is also what keeps a family name from reaching a stylesheet
  unchecked. Clearing a setting is always allowed and means "use the default".
  """
  @spec put(key(), String.t() | integer() | nil) :: t()
  def put(key, value) when key in [:ui_font, :mono_font, :font_scale] do
    case normalize(key, value) do
      {:ok, value} ->
        read() |> Map.put(Atom.to_string(key), value) |> write()
        get()

      :error ->
        get()
    end
  end

  @doc """
  The path settings are stored at.

  Overridable through `config :eva_web, :settings_path` so the test suite can't overwrite the
  settings of whoever is running it.
  """
  @spec path() :: String.t()
  def path do
    Application.get_env(:eva_web, :settings_path) || Path.join(%Paths{}.home, @filename)
  end

  # -- Private --

  defp normalize(_key, value) when value in [nil, ""], do: {:ok, nil}

  defp normalize(:font_scale, value) do
    case scale_value(value) do
      nil -> :error
      scale -> {:ok, scale}
    end
  end

  defp normalize(_key, value) when is_binary(value) do
    if Fonts.known?(value), do: {:ok, value}, else: :error
  end

  defp normalize(_key, _value), do: :error

  # A font that was uninstalled since it was picked is treated as unset rather than written into
  # the page, where it would silently fall through to the browser default anyway.
  defp font(value) do
    if is_binary(value) and Fonts.known?(value), do: value, else: nil
  end

  defp scale(value), do: scale_value(value) || @default_scale

  defp scale_value(value) when value in @scales, do: value

  defp scale_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {scale, ""} -> scale_value(scale)
      _other -> nil
    end
  end

  defp scale_value(_value), do: nil

  defp read do
    with {:ok, binary} <- File.read(path()),
         {:ok, %{} = settings} <- JSON.decode(binary) do
      settings
    else
      # A missing file is the normal first-run case. A corrupt one is worth saying something about,
      # but not worth refusing to render the app over.
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("EvaWeb.Settings: ignoring unreadable #{path()}: #{inspect(other)}")
        %{}
    end
  end

  defp write(settings) do
    file = path()
    File.mkdir_p!(Path.dirname(file))

    case File.write(file, JSON.encode_to_iodata!(settings)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("EvaWeb.Settings: could not write #{file}: #{reason}")
    end
  end
end
