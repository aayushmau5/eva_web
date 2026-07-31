defmodule EvaWeb.Proto.Fixtures do
  @moduledoc """
  Fabricated machines, projects, sessions and session-to-session links for the session browser
  prototype (`EvaWebWeb.BrowseLive`).

  None of this touches disk or a `EvaWeb.Sessions.Runner`. The point is to exercise states that
  real local data cannot show yet — several machines, every status at once, and links that cross
  a machine boundary — so the design can be judged before the distributed side of Eva exists.

  Everything here is deterministic. The only thing that changes at runtime is `advance/1`, which
  the LiveView's ticker uses to move one session to a new status.
  """

  @type status :: :working | :awaiting | :failed | :idle

  @doc """
  Machines, in display order. `:local` is the one the browser is running on.

  Ordering matters twice over: it is the order of rows in Boring View, and the order machines are
  laid out on the canvas in Fun View.
  """
  @spec machines() :: [map()]
  def machines do
    [
      %{
        id: "local",
        name: "This Machine",
        host: "aayush@mbp-14",
        kind: :local,
        os: "darwin 27.0.0"
      },
      %{
        id: "x",
        name: "Machine X",
        host: "eva@thinkpad-x1",
        kind: :remote,
        os: "arch linux"
      },
      %{
        id: "y",
        name: "Machine Y",
        host: "eva@hetzner-cx42",
        kind: :remote,
        os: "debian 13"
      }
    ]
  end

  @doc "Projects, in display order, each belonging to a machine."
  @spec projects() :: [map()]
  def projects do
    [
      %{id: "p-eva", machine_id: "local", name: "eva", path: "~/dev/eva"},
      %{id: "p-web", machine_id: "local", name: "eva_web", path: "~/dev/eva_web"},
      %{id: "p-dots", machine_id: "local", name: "dotfiles", path: "~/.dotfiles"},
      %{id: "p-nix", machine_id: "x", name: "nix-config", path: "~/src/nix-config"},
      %{id: "p-blog", machine_id: "x", name: "blog", path: "~/src/blog"},
      %{id: "p-infra", machine_id: "y", name: "infra", path: "/srv/infra"},
      %{id: "p-scrape", machine_id: "y", name: "scraper", path: "/srv/scraper"}
    ]
  end

  @doc """
  Sessions, in display order within their project.

  `preview` is what shows on the TV screen — three short lines, because that is what fits on a
  176px CRT without turning into a grey smear.
  """
  @spec sessions() :: [map()]
  def sessions do
    [
      # -- local / eva --
      session("s-01", "p-eva", "Research multi-listener subscribe API", :working, 2, [
        "reading session.ex:440",
        "forward_event/2 sends to one",
        "drafting subscribe/2..."
      ]),
      session("s-02", "p-eva", "Registry for session ownership", :awaiting, 8, [
        "two processes, same JSONL",
        "found the double-open",
        "confirm before I patch?"
      ]),
      session("s-03", "p-eva", "Fix parent-id chain in from_entries", :failed, 26, [
        "test/state_test.exs",
        "  7 tests, 3 failures",
        "** (MatchError) no match"
      ]),
      session("s-04", "p-eva", "Token accounting for tool results", :idle, 94, [
        "usage rolled into turn",
        "cache_read counted twice",
        "done — 12 files changed"
      ]),
      session("s-05", "p-eva", "MCP stdio transport retries", :idle, 180, [
        "backoff 100ms -> 3.2s",
        "gave up after 6 tries",
        "logged, not raised"
      ]),

      # -- local / eva_web --
      session("s-06", "p-web", "Session browser prototype", :working, 0, [
        "browse_live.ex +410",
        "tv_components.ex +260",
        "wiring the canvas hook"
      ]),
      session("s-07", "p-web", "Streaming deltas duplicate transcript", :awaiting, 5, [
        "AgentStart reloads history",
        "that is the duplication",
        "drop the reload?"
      ]),
      session("s-08", "p-web", "Font settings reach the flashes", :idle, 47, [
        "--font-sans on wrapper",
        "contents, not a box",
        "shipped"
      ]),
      session("s-09", "p-web", "Markdown tables render", :idle, 320, [
        "MDEx pipeline",
        "overflow-x on the wrapper",
        "shipped"
      ]),

      # -- local / dotfiles --
      session("s-10", "p-dots", "Migrate fish config to nix", :idle, 610, [
        "abbr -> shellAbbrs",
        "34 functions moved",
        "home-manager switch ok"
      ]),
      session("s-11", "p-dots", "Neovim LSP for elixir-ls", :failed, 730, [
        "elixir_ls not on PATH",
        "expected in .elixir_ls/",
        "** (RuntimeError)"
      ]),

      # -- x / nix-config --
      session("s-12", "p-nix", "Pin nixpkgs to 25.05", :working, 1, [
        "flake.lock rewrite",
        "rebuilding 214 drvs",
        "eta ~4m"
      ]),
      session("s-13", "p-nix", "Cachix for CI builds", :idle, 88, [
        "push key in secrets",
        "hit rate 91%",
        "done"
      ]),
      session("s-14", "p-nix", "Split host modules", :awaiting, 33, [
        "thinkpad vs hetzner",
        "shared/ or common/?",
        "waiting on naming"
      ]),

      # -- x / blog --
      session("s-15", "p-blog", "Write up eva's event loop", :idle, 240, [
        "three hops, all send/2",
        "draft at 1400 words",
        "needs a diagram"
      ]),
      session("s-16", "p-blog", "RSS feed dates are wrong", :failed, 400, [
        "RFC822 vs ISO8601",
        "readers show 1970",
        "1 test failing"
      ]),

      # -- y / infra --
      session("s-17", "p-infra", "Distributed eva node discovery", :working, 3, [
        "dns_cluster + :pg",
        "3 nodes connected",
        "watching netsplit"
      ]),
      session("s-18", "p-infra", "Rotate deploy keys", :awaiting, 17, [
        "old key still on 2 hosts",
        "rotate now or at 02:00?",
        "needs a yes"
      ]),
      session("s-19", "p-infra", "Postgres backup verification", :idle, 155, [
        "pg_restore --list ok",
        "checksum matches",
        "nightly at 03:15"
      ]),

      # -- y / scraper --
      session("s-20", "p-scrape", "Rate limit backoff", :idle, 520, [
        "429 -> retry-after",
        "jitter added",
        "shipped"
      ]),
      session("s-21", "p-scrape", "Parse malformed feed entries", :failed, 640, [
        "unclosed CDATA",
        "12 entries dropped",
        "** (Saxy.ParseError)"
      ])
    ]
  end

  @doc """
  Session-to-session links, as `{from_id, to_id}`.

  Deliberately weighted toward crossing a machine boundary, since a link that stays inside one
  project is the case the design already handles by sitting things next to each other.
  """
  @spec links() :: [{String.t(), String.t()}]
  def links do
    [
      # a chain of work inside eva
      {"s-01", "s-02"},
      {"s-02", "s-03"},
      {"s-03", "s-04"},
      # the web prototype leans on the eva-side API work
      {"s-06", "s-01"},
      {"s-07", "s-06"},
      # local -> x
      {"s-04", "s-12"},
      {"s-05", "s-14"},
      {"s-15", "s-01"},
      # local -> y
      {"s-01", "s-17"},
      {"s-06", "s-17"},
      {"s-10", "s-18"},
      # x -> y
      {"s-12", "s-19"},
      {"s-13", "s-18"},
      # within y
      {"s-17", "s-18"},
      {"s-20", "s-21"}
    ]
  end

  # -- Status --

  @doc "Every status, in the order the legend lists them."
  @spec statuses() :: [status()]
  def statuses, do: [:working, :awaiting, :failed, :idle]

  @doc "Human label for a status."
  @spec status_label(status()) :: String.t()
  def status_label(:working), do: "working"
  def status_label(:awaiting), do: "awaiting input"
  def status_label(:failed), do: "failed"
  def status_label(:idle), do: "idle"

  @doc """
  Picks one session and gives it a new status, for the LiveView's demo ticker.

  Weighted rather than uniform: a real wall of sessions is mostly idle, and a browser that shows
  everything blinking at once would flatter the design dishonestly. Sessions carrying the `:failed`
  state are left alone for a while so a red light is something you can actually notice.
  """
  @spec advance(%{String.t() => map()}) :: {String.t(), status()} | nil
  def advance(sessions) when map_size(sessions) > 0 do
    {id, session} = Enum.random(sessions)
    {id, next_status(session.status)}
  end

  def advance(_sessions), do: nil

  defp next_status(:working), do: weighted(idle: 5, awaiting: 3, failed: 1, working: 6)
  defp next_status(:awaiting), do: weighted(working: 6, idle: 2, awaiting: 6)
  defp next_status(:failed), do: weighted(failed: 8, working: 2, idle: 1)
  defp next_status(:idle), do: weighted(idle: 10, working: 3, awaiting: 1)

  defp weighted(choices) do
    total = choices |> Keyword.values() |> Enum.sum()

    Enum.reduce_while(choices, :rand.uniform(total), fn {status, weight}, left ->
      if left <= weight, do: {:halt, status}, else: {:cont, left - weight}
    end)
  end

  # -- Private --

  defp session(id, project_id, title, status, minutes_ago, preview) do
    project = Enum.find(projects(), &(&1.id == project_id))

    %{
      id: id,
      project_id: project_id,
      machine_id: project.machine_id,
      title: title,
      status: status,
      minutes_ago: minutes_ago,
      preview: preview,
      model: model_for(id),
      turns: 3 + rem(:erlang.phash2(id), 28),
      tokens: 1200 + rem(:erlang.phash2(id), 90) * 900
    }
  end

  # Spread deterministically rather than randomly so the same session always claims the same model
  # across reloads — a detail drawer that changes its mind is distracting to look at.
  @models ["claude-opus-5", "claude-sonnet-5", "deepseek-v4-pro", "gpt-5.2"]
  defp model_for(id), do: Enum.at(@models, rem(:erlang.phash2(id), length(@models)))
end
