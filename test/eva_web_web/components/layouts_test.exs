defmodule EvaWebWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvaWebWeb.Layouts

  defp app(settings) do
    render_component(&Layouts.app/1,
      flash: %{},
      settings: Map.merge(%{ui_font: nil, mono_font: nil, font_scale: 100}, settings),
      inner_block: [%{inner_block: fn _slot, _assigns -> "content" end, __slot__: :inner_block}]
    )
  end

  test "sets no font variables when nothing is chosen" do
    html = app(%{ui_font: nil, mono_font: nil})

    refute html =~ "--font-sans"
    refute html =~ "--font-mono"
    refute html =~ "--text-"
  end

  # Overriding Tailwind's own variables is what makes the choice reach `code`, `pre` and every
  # font-mono utility in the tree, rather than only the element it is set on.
  test "overrides Tailwind's font variables with the chosen families" do
    html = app(%{ui_font: "Inter", mono_font: "Berkeley Mono"})

    assert html =~ ~s{--font-sans: &quot;Inter&quot;}
    assert html =~ ~s{--font-mono: &quot;Berkeley Mono&quot;}
  end

  # A font missing a script — or a box-drawing glyph — has to have somewhere to fall through to.
  test "keeps a fallback stack behind the chosen family" do
    html = app(%{ui_font: "Inter", mono_font: "Berkeley Mono"})

    assert html =~ "ui-sans-serif"
    assert html =~ "ui-monospace"
  end

  test "sets only the variable that was chosen" do
    html = app(%{ui_font: nil, mono_font: "Berkeley Mono"})

    refute html =~ "--font-sans"
    assert html =~ "--font-mono"
  end

  # Every `text-*` utility compiles to `var(--text-<step>)`, so restating the ramp is what makes
  # one setting resize all of them — including the three sub-`xs` steps this app adds.
  test "restates the whole type ramp at the chosen scale" do
    html = app(%{font_scale: 150})

    assert html =~ "--text-xs: 1.125rem;"
    assert html =~ "--text-sm: 1.3125rem;"
    assert html =~ "--text-2xs: 1.0313rem;"
    assert html =~ "--text-4xs: 0.8438rem;"
  end

  test "leaves the ramp alone at 100%" do
    refute app(%{font_scale: 100}) =~ "--text-"
  end

  test "scales alongside a chosen family" do
    html = app(%{ui_font: "Inter", font_scale: 125})

    assert html =~ "--font-sans"
    assert html =~ "--text-xs: 0.9375rem;"
  end

  # Settings validates against the installed families, so this can't normally happen — but the
  # value lands in a style attribute, and that is not a place to rely on one check. What matters
  # is that the family stays a single quoted token: the characters that could end it early are
  # gone, so nothing after it is ever read as a declaration of its own.
  test "a family cannot break out of the style attribute" do
    html = app(%{ui_font: ~s(Evil"; background: url\(x\); a: "), mono_font: nil})

    assert [_, style] = Regex.run(~r/style="([^"]*)"/, html)
    assert String.starts_with?(style, "--font-sans: &quot;Evil background: url(x) a: &quot;,")
    assert String.ends_with?(style, ";")
    # One declaration, so one terminator — counted past the `;` in each escaped quote.
    assert style |> String.replace("&quot;", "'") |> String.split(";") |> length() == 2
  end
end
