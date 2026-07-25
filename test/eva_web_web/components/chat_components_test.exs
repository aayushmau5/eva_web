defmodule EvaWebWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  alias EvaWebWeb.ChatComponents

  defp render(text), do: text |> ChatComponents.markdown() |> Phoenix.HTML.safe_to_string()

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
      assert html =~ "background-color:#111b27"
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
end
