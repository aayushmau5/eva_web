defmodule EvaWebWeb.Mermaid do
  @moduledoc """
  An MDEx plugin that gives `MDExMermex` somewhere to fail.

  Mermex parses a diagram in Rust and raises when it cannot, and MDEx lets that through — so a
  single unparseable fence takes down the render of the whole message it sits in. This wraps the
  codefence renderer MDExMermex installed and catches that, leaving the rest of the message alone.

  Attach it *after* `MDExMermex`, whose renderer it replaces with a wrapped copy:

      MDEx.to_html(text, plugins: [{MDExMermex, ...}, {EvaWebWeb.Mermaid, show_errors: true}])

  ## Why the error is not always shown

  A message arrives a token at a time, and for most of a diagram's arrival the fence is
  half-written and cannot parse. That failure is not worth reporting — it is just the diagram not
  having finished — so `:show_errors` is false while a message streams and the block shows its
  source like any other code fence. Once the message has landed, a fence that still won't parse is
  a real one, and the parser's complaint is the only thing that says which line to go and fix.

  Mermex is a reimplementation rather than mermaid.js itself, so the diagrams it turns down are not
  always wrong: block constructs inside a `sequenceDiagram` — `alt`/`else`, `loop`, `opt` — are
  valid mermaid it does not implement, and they fail with a complaint about `end`. Showing the
  message is what makes that difference visible instead of looking like a silent nothing.
  """

  alias MDEx.Document

  @doc "Attaches to `document`. Accepts `:show_errors`, defaulting to true."
  @spec attach(Document.t(), keyword()) :: Document.t()
  def attach(document, options \\ []) do
    document
    |> Document.register_options([:show_errors])
    |> Document.put_options(options)
    |> Document.append_steps(guard_mermaid: &guard/1)
  end

  # Appended after MDExMermex's own `register_codefence` step, so by the time this runs its
  # renderer is in the document and can be wrapped rather than reimplemented — the diagram markup
  # stays the package's.
  defp guard(document) do
    renderers = Document.get_option(document, :codefence_renderers, %{})
    show_errors? = Document.get_option(document, :show_errors) != false

    case Map.fetch(renderers, "mermaid") do
      {:ok, render} ->
        Document.put_codefence_renderers(document, %{
          "mermaid" => &guarded(render, &1, &2, &3, show_errors?)
        })

      :error ->
        document
    end
  end

  defp guarded(render, lang, meta, code, show_errors?) do
    render.(lang, meta, code) |> darken()
  rescue
    error -> fallback(code, Exception.message(error), show_errors?)
  end

  # Mermex draws on white in Tailwind slate and has no theme option — it ignores `%%{init}%%` and
  # frontmatter config alike, so the only place left to change the colours is the SVG it hands back.
  # Every colour it can emit is in the table below, which is short because the palette is hardcoded
  # in the Rust crate: slate for structure, one orange for a sequence diagram's notes.
  #
  # Mapped onto the zinc the rest of a message is written in, keeping each colour's job — the
  # canvas is `.md code`'s background, the text is `.md`'s own, and the strokes sit between them.
  # A colour not in the table is left alone, so a diagram that styles itself keeps what it asked
  # for. `.md .mdex-mermex` in `app.css` repeats the canvas colour to pad the diagram with.
  @palette %{
    # canvas
    "#FFFFFF" => "#1c1c1c",
    # node and lane fills, lightest first
    "#F8FAFC" => "#27272a",
    "#F1F5F9" => "#27272a",
    "#E2E8F0" => "#3f3f46",
    "#CBD5E1" => "#52525b",
    # strokes
    "#94A3B8" => "#52525b",
    "#64748B" => "#a1a1aa",
    # text
    "#0F172A" => "#e4e4e7",
    # a sequence diagram's notes, the one thing that isn't slate
    "#FFF7ED" => "#3a2a12",
    "#FDBA74" => "#b45309"
  }

  # The SVG is already base64 inside the <img> the package built, so recolouring means going back
  # through the data URI. Cheaper than the alternative, which is reimplementing the wrapper markup
  # that `assets/mdex_mermex.js` is written against. A src that will not decode is left as it is.
  defp darken(html) do
    Regex.replace(~r|(src="data:image/svg\+xml;base64,)([A-Za-z0-9+/=]+)(")|, html, fn
      _match, prefix, encoded, suffix ->
        case Base.decode64(encoded) do
          {:ok, svg} -> prefix <> Base.encode64(recolour(svg)) <> suffix
          :error -> prefix <> encoded <> suffix
        end
    end)
  end

  defp recolour(svg) do
    Regex.replace(~r/#[0-9A-Fa-f]{6}\b/, svg, fn colour ->
      Map.get(@palette, String.upcase(colour), colour)
    end)
  end

  # The source is shown as a plain code block either way: a diagram that didn't draw is still
  # something the reader can read, and it is what a ```mermaid fence looked like before any of this
  # existed. Both `pre`/`code` and `div class` survive the sanitizer these strings are about to
  # meet — see `EvaWebWeb.ChatComponents.markdown/2`.
  defp fallback(code, message, show_errors?) do
    source = "<pre><code class=\"language-mermaid\">#{escape(code)}</code></pre>"

    if show_errors? do
      ~s(<div class="md-diagram-error">) <>
        ~s(<div class="md-diagram-error-note">#{escape(strip_prefix(message))}</div>) <>
        source <> "</div>"
    else
      source
    end
  end

  # Mermex prefixes its own name onto the parser's message. The reader is looking at a diagram that
  # didn't draw and already knows that much; the part worth the width is where in it to look.
  defp strip_prefix("Mermex render failed: " <> rest), do: rest
  defp strip_prefix(message), do: message

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
