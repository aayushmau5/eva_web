defmodule EvaWeb.SettingsTest do
  # Not async: every test in here writes the one settings file.
  use ExUnit.Case, async: false

  alias EvaWeb.Fonts
  alias EvaWeb.Settings

  setup do
    File.rm(Settings.path())
    on_exit(fn -> File.rm(Settings.path()) end)

    %{mono: [mono | _], ui: [ui | _]} = Fonts.list()
    %{a_mono_font: mono, a_font: ui}
  end

  test "starts out unset" do
    assert Settings.get() == %{ui_font: nil, mono_font: nil, font_scale: 100}
  end

  test "keeps a font that the machine has", %{a_font: font} do
    assert %{ui_font: ^font} = Settings.put(:ui_font, font)
    assert %{ui_font: ^font} = Settings.get()
  end

  test "keeps the two fonts independently", %{a_font: font, a_mono_font: mono} do
    Settings.put(:ui_font, font)
    Settings.put(:mono_font, mono)

    assert %{ui_font: ^font, mono_font: ^mono} = Settings.get()
  end

  test "clearing a font restores the default", %{a_font: font} do
    Settings.put(:ui_font, font)

    assert %{ui_font: nil} = Settings.put(:ui_font, nil)
    assert %{ui_font: nil} = Settings.put(:ui_font, "")
  end

  # The stored value ends up inside a style attribute, so this is the boundary that keeps a font
  # name from being anything other than a font name.
  test "refuses a font the machine does not have", %{a_font: font} do
    Settings.put(:ui_font, font)

    assert %{ui_font: ^font} = Settings.put(:ui_font, "No Such Font 91827")
    assert %{ui_font: ^font} = Settings.put(:ui_font, ~s(x"; background: url\(evil\)))
    assert %{ui_font: ^font} = Settings.put(:ui_font, :not_a_string)
  end

  test "ignores a font that has since been uninstalled" do
    File.write!(Settings.path(), ~s({"ui_font": "Uninstalled Font 91827"}))

    assert %{ui_font: nil} = Settings.get()
  end

  describe "font scale" do
    test "accepts a scale that is on offer, as the string the form sends" do
      scale = Settings.scales() |> Enum.reject(&(&1 == 100)) |> hd()

      assert %{font_scale: ^scale} = Settings.put(:font_scale, to_string(scale))
      assert %{font_scale: ^scale} = Settings.get()
    end

    # The scale multiplies the type ramp the layout is built around, so a value nobody designed
    # for has no business being stored.
    test "refuses a scale that is not on offer" do
      Settings.put(:font_scale, 125)

      assert %{font_scale: 125} = Settings.put(:font_scale, 400)
      assert %{font_scale: 125} = Settings.put(:font_scale, "not a number")
      assert %{font_scale: 125} = Settings.put(:font_scale, "125%")
    end

    test "clearing it goes back to 100%" do
      Settings.put(:font_scale, 125)

      assert %{font_scale: 100} = Settings.put(:font_scale, nil)
    end

    test "ignores a stored scale this version no longer offers" do
      File.write!(Settings.path(), ~s({"font_scale": 400}))

      assert %{font_scale: 100} = Settings.get()
    end
  end

  test "survives a corrupt settings file" do
    File.write!(Settings.path(), "{ not json")

    assert Settings.get() == %{ui_font: nil, mono_font: nil, font_scale: 100}
  end

  # A newer Eva may store settings this version knows nothing about; writing a font must not be
  # what silently drops them.
  test "leaves keys it does not understand alone", %{a_font: font} do
    File.write!(Settings.path(), ~s({"theme": "solarized"}))

    Settings.put(:ui_font, font)

    assert {:ok, %{"theme" => "solarized"}} = Settings.path() |> File.read!() |> JSON.decode()
  end
end
