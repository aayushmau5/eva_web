// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/eva_web"
import topbar from "../vendor/topbar"

const Hooks = {
  ...colocatedHooks,

  // Follows the stream only while the reader is already at the bottom. Scrolling up to read
  // earlier output has to win over incoming deltas, otherwise every token drags the viewport
  // back down.
  ScrollToBottom: {
    mounted() {
      this.follow = true
      // Driven by real scroll events rather than sampled during a patch: this element is the
      // phx-update="stream" container, and beforeUpdate does not fire for it when only its
      // children change, so anything captured there stays stuck at its mounted value.
      this.el.addEventListener("scroll", () => {
        // Our own scrolling must not be mistaken for the reader's.
        if (!this.programmatic) this.follow = this.atBottom()
      })
      this.scroll()
    },
    updated() {
      if (this.follow) this.scroll()
    },
    atBottom() {
      // A little slack: "close enough to the bottom" counts as following along.
      return this.maxScroll() - this.el.scrollTop < 40
    },
    maxScroll() {
      return this.el.scrollHeight - this.el.clientHeight
    },
    scroll() {
      // Deferred to the next frame so the position is computed against settled layout. Writing
      // during the patch reads a container that is momentarily short — mid-replacement — and pins
      // the reader to the top, which then fights whatever they were doing.
      cancelAnimationFrame(this.raf)
      this.raf = requestAnimationFrame(() => {
        const max = this.maxScroll()
        if (max <= 0) return
        if (Math.abs(this.el.scrollTop - max) <= 1) return
        this.programmatic = true
        this.el.scrollTop = max
        requestAnimationFrame(() => (this.programmatic = false))
      })
    },
    destroyed() {
      cancelAnimationFrame(this.raf)
    },
  },

  // Whether a <details> is open lives only in the DOM — the server never renders `open`, so a patch
  // strips whatever the user expanded. While a message streams that happens on every delta, which
  // snapped thinking blocks shut mid-read.
  //
  // Intent is tracked from the `toggle` event rather than read off the element during a patch:
  // reading mid-patch picked up transient states and left fresh blocks expanded on their own. Here
  // the element is simply forced back to the last state the user actually chose.
  KeepOpen: {
    mounted() {
      this.userOpen = this.el.open
      this.el.addEventListener("toggle", () => (this.userOpen = this.el.open))
    },
    updated() {
      if (this.el.open !== this.userOpen) this.el.open = this.userOpen
    },
  },

  // Copies a message by reading it back off the page. The text is already rendered, so nothing has
  // to be sent down twice — which matters most for assistant messages, whose every streamed delta
  // would otherwise carry a second copy of themselves.
  Copy: {
    mounted() {
      this.el.addEventListener("click", () => {
        const body = document.getElementById(this.el.dataset.copyFrom)
        if (!body) return
        // Assistant messages mark their prose, so thinking blocks stay out of the clipboard. A
        // user bubble has no parts and is copied whole.
        const parts = [...body.querySelectorAll("[data-copy-part]")]
        const text = (parts.length ? parts : [body]).map(node => node.innerText).join("\n\n")
        this.write(text).then(ok => ok && this.confirm())
      })
    },
    // navigator.clipboard is only there on a secure origin, which this app is not once it is
    // served to anything but localhost — so the old selection dance stays as the fallback.
    write(text) {
      if (navigator.clipboard) {
        return navigator.clipboard.writeText(text).then(() => true, () => this.writeLegacy(text))
      }
      return Promise.resolve(this.writeLegacy(text))
    },
    writeLegacy(text) {
      const area = document.createElement("textarea")
      area.value = text
      // Off-screen rather than hidden: the selection only works on a rendered element.
      area.style.cssText = "position:fixed;top:-9999px;opacity:0"
      document.body.appendChild(area)
      area.select()
      const ok = document.execCommand("copy")
      area.remove()
      return ok
    },
    // Long enough to notice, short enough not to look like a stuck state.
    confirm() {
      clearTimeout(this.timer)
      this.toggle(true)
      this.timer = setTimeout(() => this.toggle(false), 1200)
    },
    // Both icons carry `flex`, so only `hidden` moves — swapping the two for classes that lay out
    // differently is what makes the row jump.
    toggle(copied) {
      this.el.querySelector("[data-icon=idle]").classList.toggle("hidden", copied)
      const done = this.el.querySelector("[data-icon=done]")
      done.classList.toggle("hidden", !copied)
      done.classList.toggle("flex", copied)
    },
    destroyed() {
      clearTimeout(this.timer)
    },
  },

  ChatInput: {
    mounted() {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          const text = this.el.value.trim()
          if (text) {
            this.pushEvent("send", {text})
            this.reset()
          }
          return
        }
        // `!` on an empty box is a mode switch rather than a character — the same key that gets
        // you into command mode gets you one further, into the one the model never sees. Anywhere
        // else in the line it is just a `!`, which shell commands are full of.
        if (e.key === "!" && this.el.value === "") {
          const next = {prompt: "command", command: "private_command"}[this.mode()]
          if (next) {
            e.preventDefault()
            this.pushEvent("set_mode", {mode: next})
          }
          return
        }
        // Backing out the way you came in: backspace on an empty box undoes the last `!`.
        if (e.key === "Backspace" && this.el.value === "") {
          const back = {command: "prompt", private_command: "command"}[this.mode()]
          if (back) {
            e.preventDefault()
            this.pushEvent("set_mode", {mode: back})
          }
          return
        }
        if (e.key === "Escape" && this.mode() !== "prompt") {
          e.preventDefault()
          this.pushEvent("set_mode", {mode: "prompt"})
        }
      })
      this.el.addEventListener("input", () => this.grow())
      // Cleared from the server after the prompt is accepted. Clearing it on the form's own
      // submit event would race LiveView's serialization and send an empty message.
      this.handleEvent("chat:clear", () => this.reset())
      // Forking drops the message it branched at back in here to be reworked. The caret goes to
      // the end so typing continues the prompt instead of landing in front of it.
      this.handleEvent("chat:fill", ({text}) => {
        this.el.value = text
        this.grow()
        this.el.focus()
        this.el.setSelectionRange(text.length, text.length)
      })
      // Cycling the mode from the pill puts the caret back where the typing happens.
      this.handleEvent("chat:focus", () => this.el.focus())
      this.grow()
    },
    // Read off the element each time rather than cached: the server owns the mode and re-renders
    // the attribute, so anything remembered here goes stale the moment the pill is clicked.
    mode() {
      return this.el.dataset.mode || "prompt"
    },
    grow() {
      const max = 144
      this.el.style.height = "auto"
      // scrollHeight covers the content and its padding but not the border, and the box is
      // border-box — so assigning it straight across leaves the last line a border's worth short
      // and permanently scrolled.
      const style = getComputedStyle(this.el)
      const border = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth)
      this.el.style.height = Math.min(this.el.scrollHeight + border, max) + "px"
      // A one-line textarea still reports a scrollHeight a hair over its box, so the scrollbar
      // shows before there is anything to scroll. Only allow it once the box stops growing.
      this.el.style.overflowY = this.el.scrollHeight + border > max ? "auto" : "hidden"
    },
    reset() {
      this.el.value = ""
      this.grow()
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

