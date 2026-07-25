## Chats

```
Let me pull up the exact code paths so this is concrete rather than hand-wavy.

Fair — I was too abstract. Let me start from what the code actually does.

## The event path today

```
Loop ──spawns──> emits events
  │
  └─send──> Harness      (harness.ex:308)  send(state.coding_session_pid, event)
              │
              └─send──> Session  (session.ex:440)  send(state.config.listener_pid, event)
                          │
                          └─send──> whoever was passed as listener_pid at start_link
```

Three hops, all raw `send/2`. The last hop is the one that matters:

```elixir
defp forward_event(state, event) do
  if state.config.listener_pid do
    send(state.config.listener_pid, event)
  end
end
```

`listener_pid` is a field on `SessionConfig`, set once when the session starts, never changed. **One listener. Fixed for the session's lifetime.**

---

# 7. The single-listener problem

## What breaks, concretely

**Open the same session in two browser tabs.** Tab A starts the session and is the listener. Tab B attaches — but `listener_pid` is already Tab A's pid, and there's no API to add another. Tab B sees a static transcript and never updates. Without a workaround, eva structurally supports exactly one viewer per session.

**Hit refresh.** A LiveView gets a *new process* on reconnect. The old pid is dead; `listener_pid` still points at it. `send/2` to a dead pid returns `:ok` and silently discards — so the session keeps running, keeps writing to disk, and streams into the void. Nothing errors. The UI just goes quiet.

**Attach to a session someone else started.** The CLI (`mix herd`) starts a session with itself as listener. You can't later attach a web UI to watch it. The listener slot is taken.

**eva can't tell if anyone is listening.** No `Process.monitor`, so no way to stop work when the last viewer leaves.

## What I built to dodge this

The Runner is a long-lived process that is *permanently* the listener, and re-broadcasts:

```
Session ──send──> Runner ──PubSub.broadcast──> N LiveViews (come and go freely)
         (fixed)            (dynamic)
```

That works, but note what it is: **an adapter that exists solely because the listener slot is singular.** If eva supported N listeners, the Runner would lose most of its purpose.

## Options

**(a) A list of listeners — smallest change, no new deps.**

```elixir
# SessionConfig gets listeners: [pid()] instead of listener_pid
def subscribe(pid, listener \\ self()), do: GenServer.call(pid, {:subscribe, listener})
def unsubscribe(pid, listener \\ self()), do: GenServer.call(pid, {:unsubscribe, listener})

def handle_call({:subscribe, listener}, _from, state) do
  Process.monitor(listener)                      # eva learns when viewers die
  {:reply, :ok, %{state | listeners: [listener | state.listeners]}}
end

def handle_info({:DOWN, _ref, :process, pid, _}, state) do
  {:noreply, %{state | listeners: List.delete(state.listeners, pid)}}
end

defp forward_event(state, event) do
  Enum.each(state.listeners, &send(&1, event))
end
```

Roughly 25 lines. Solves all four problems above. eva_web could then subscribe LiveViews directly and the Runner drops to just "keeps the session alive."

**(b) `:pg`** — OTP's process groups. Same effect, and it works across a distributed cluster (relevant to your `idea.png`, where eva runs on several machines). But it's global mutable state, and it's overkill until you actually go multi-node.

**(c) A dispatch callback** — `SessionConfig.on_event: (event -> :ok)`. Maximum flexibility, eva stays out of the business entirely. But then eva can't monitor listeners, and every consumer reinvents fan-out. This is basically what you have now, dressed up.

**My read:** (a). It's small, needs no dependency, and it's the thing everything else is currently bending around. (b) later if you go multi-node.

---

# 8. The process-ownership problem

```elixir
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts)   # no name, no registry
end
```

You get back a bare pid. Two consequences follow.

## No name means no way to find it again

If you lose the pid, the session is unreachable — even though it's still running and still writing to disk. Every consumer must build its own pid bookkeeping. I built a `Registry` keyed by session id; a TUI would build something else; they wouldn't interoperate.

## Nothing prevents starting the same session twice

This is the sharp edge. Nothing in eva stops this:

```elixir
{:ok, a} = Session.start_link(%{config: config})   # session_id "abc"
{:ok, b} = Session.start_link(%{config: config})   # same session_id "abc"
```

Now **two processes have the same JSONL open and both append to it.** Each has its own `persisted_count`, so they interleave entries and corrupt the parent-id chain that `State.from_entries/2` walks. You'd get a mangled transcript with no error at write time.

Today you're safe only because eva_web's Registry enforces uniqueness. Run the CLI and the web app against the same session and you're exposed — and that's exactly the multi-frontend future you're building toward.

## And `start_link` means the caller's death kills the session

`start_link` creates a *bidirectional* link. In the original `home_live.ex`, the session was started from the LiveView, so navigating away killed the agent mid-tool-call. That's why my Runner exists as a supervised owner.

## Options

**(a) eva stays out of it, but supports being named.**

```elixir
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: opts[:name])
end
```

One line. Callers pass `name: {:via, Registry, {MyRegistry, session_id}}`. eva provides *addressability*; the app chooses the policy. A TUI passes nothing.

**(b) eva ships the whole thing** — its own `Registry` + `DynamicSupervisor`, and `Eva.open_session(session_id)` returns an existing session or starts one. This is the only option that actually **prevents the double-open corruption**, because eva owns the uniqueness guarantee. Cost: eva's application tree grows, and a single-session TUI carries machinery it doesn't need.

**(c) Hybrid** — (a) plus an optional `Eva.SessionSupervisor` you can add to your own tree. Apps that want it get it; the TUI ignores it.

**My read:** (c). But the uniqueness guarantee is worth taking seriously on its own — even under (a), a `:global` or file-lock check inside `Session.init` that refuses to open an already-open `session_id` would close the corruption hole cheaply.

---

# Why these two are one decision

Because **subscription needs an address.**

If eva has no registry (option 8a), then `subscribe` must take a pid — the caller already has to know the pid, so the registry problem is just pushed outward:

```elixir
Session.subscribe(pid)          # you must already hold the pid
```

If eva does have a registry (8b/8c), subscription can be by identity, which is what a web app actually wants — a LiveView knows the session *id* from the URL, not a pid:

```elixir
Eva.subscribe("abc123")         # attach by id, no pid bookkeeping
```

So: **answering 8 determines what 7's API can look like.** Do 7 alone and you get a pid-based API that every consumer wraps in its own lookup layer — which is the duplication you're trying to avoid.

## Concrete suggestion

Do them together, in this order:

1. `name:` passthrough on `Session.start_link` — 1 line, unblocks everything.
2. Multi-listener `subscribe`/`unsubscribe` with monitors — ~25 lines, pid-based.
3. Optional `Eva.SessionSupervisor` + registry in eva, and `Eva.subscribe(session_id)` on top of step 2.
4. Refuse to open an already-open `session_id`.

After that, eva_web's Runner shrinks to a thin supervision anchor, and the double-open hazard is closed before a second frontend exists.
```
