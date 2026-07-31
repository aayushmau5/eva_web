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

// Pan/zoom survives the hook being torn down and rebuilt, which is what switching to Boring View
// and back does. Losing your place on the canvas every time you glance at the other view would
// make the toggle unusable.
let canvasCamera = null

const Hooks = {
  ...colocatedHooks,

  // Horizontal scroller for one project's row of TVs, with arrows that only appear when there is
  // somewhere to go.
  ScrollRow: {
    mounted() {
      this.scroller = this.el.querySelector("[data-scroller]")
      this.buttons = [...this.el.querySelectorAll("[data-scroll]")]
      this.buttons.forEach((button) => {
        button.addEventListener("click", () => {
          const dir = Number(button.dataset.scroll)
          this.scroller.scrollBy({left: dir * this.scroller.clientWidth * 0.8, behavior: "smooth"})
        })
      })
      this.sync = () => this.syncArrows()
      this.scroller.addEventListener("scroll", this.sync, {passive: true})
      window.addEventListener("resize", this.sync)
      this.syncArrows()
    },
    updated() {
      this.syncArrows()
    },
    syncArrows() {
      const max = this.scroller.scrollWidth - this.scroller.clientWidth
      this.buttons.forEach((button) => {
        const atEnd = Number(button.dataset.scroll) < 0
          ? this.scroller.scrollLeft <= 1
          : this.scroller.scrollLeft >= max - 1
        button.toggleAttribute("data-hidden", atEnd)
      })
    },
    destroyed() {
      window.removeEventListener("resize", this.sync)
    },
  },

  // The Fun View canvas: one transform on the world for pan/zoom, absolute positions on the nodes
  // for dragging.
  //
  // While a node is dragged, the wires and the boundary boxes are recomputed here rather than
  // round-tripping to the server — at 60fps that would be a message per frame, and the wire would
  // visibly lag the TV it is attached to. The server is told once, on drop. The rules below have
  // to match `EvaWeb.Proto.Layout`; the constants come from it as data attributes so at least the
  // numbers cannot drift.
  Canvas: {
    mounted() {
      this.world = this.el.querySelector("#canvas-world")
      this.metrics = {
        nodeW: Number(this.el.dataset.nodeW),
        nodeH: Number(this.el.dataset.nodeH),
        projectPad: Number(this.el.dataset.projectPad),
        machinePad: Number(this.el.dataset.machinePad),
        labelGap: Number(this.el.dataset.labelGap),
      }

      // Note the fresh case *before* applying, since applying is what populates `canvasCamera`.
      const firstOpen = !canvasCamera
      this.camera = canvasCamera || {x: 0, y: 0, scale: 1}
      this.applyCamera()
      // Deferred a frame so the viewport has been laid out and `fit` measures a real box.
      if (firstOpen) requestAnimationFrame(() => this.fit())

      this.onDown = (e) => this.handleDown(e)
      this.onMove = (e) => this.handleMove(e)
      this.onUp = (e) => this.handleUp(e)
      this.onWheel = (e) => this.handleWheel(e)

      this.el.addEventListener("mousedown", this.onDown)
      window.addEventListener("mousemove", this.onMove)
      window.addEventListener("mouseup", this.onUp)
      // A button released outside the window never produces a mouseup, which would otherwise leave
      // the canvas stuck in a drag the user has already finished.
      window.addEventListener("blur", this.onUp)
      this.el.addEventListener("wheel", this.onWheel, {passive: false})

      // A drag that ends on a node would otherwise be delivered as a click, i.e. as "select".
      this.onClick = (e) => {
        if (this.suppressClick) {
          e.preventDefault()
          e.stopPropagation()
          this.suppressClick = false
        }
      }
      this.el.addEventListener("click", this.onClick, true)

      this.el.querySelectorAll("[data-zoom]").forEach((button) => {
        button.addEventListener("click", () => {
          const action = button.dataset.zoom
          if (action === "fit") this.fit()
          else this.zoomBy(action === "in" ? 1.2 : 1 / 1.2)
        })
      })
    },

    // Everything this hook writes to the DOM is invisible to the server, so every patch of the
    // canvas undoes it: the world's transform (the server renders no style attribute at all) and
    // the drag classes (the server renders a fixed class list). Reapplying after each update is
    // what stops the view snapping back to the origin, and the drop-target highlight vanishing
    // under the cursor, whenever the demo ticker changes a session's status.
    updated() {
      this.applyCamera()
      this.paintDrag()
    },

    destroyed() {
      window.removeEventListener("mousemove", this.onMove)
      window.removeEventListener("mouseup", this.onUp)
      window.removeEventListener("blur", this.onUp)
    },

    // -- Camera --

    applyCamera() {
      const {x, y, scale} = this.camera
      this.world.style.transform = `translate(${x}px, ${y}px) scale(${scale})`
      // The dot grid is the viewport's background, so it has to be moved and scaled by hand —
      // otherwise it stays nailed to the screen and the canvas reads as a fixed page.
      this.el.style.backgroundSize = `${28 * scale}px ${28 * scale}px`
      this.el.style.backgroundPosition = `${x}px ${y}px`
      canvasCamera = {...this.camera}
    },

    zoomAt(scale, clientX, clientY) {
      const next = Math.min(2.5, Math.max(0.15, scale))
      const rect = this.el.getBoundingClientRect()
      // Keep whatever is under the pointer under the pointer.
      const px = clientX - rect.left
      const py = clientY - rect.top
      const ratio = next / this.camera.scale
      this.camera.x = px - (px - this.camera.x) * ratio
      this.camera.y = py - (py - this.camera.y) * ratio
      this.camera.scale = next
      this.applyCamera()
    },

    zoomBy(factor) {
      const rect = this.el.getBoundingClientRect()
      this.zoomAt(this.camera.scale * factor, rect.left + rect.width / 2, rect.top + rect.height / 2)
    },

    fit() {
      const boxes = [...this.el.querySelectorAll('[data-box="machine"]')]
      if (boxes.length === 0) return
      const bounds = boxes.reduce(
        (acc, box) => {
          const {x, y, w, h} = this.boxRect(box)
          return {
            minX: Math.min(acc.minX, x),
            minY: Math.min(acc.minY, y - this.metrics.labelGap),
            maxX: Math.max(acc.maxX, x + w),
            maxY: Math.max(acc.maxY, y + h),
          }
        },
        {minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity},
      )

      const pad = 60
      const rect = this.el.getBoundingClientRect()
      const scale = Math.min(
        2.5,
        Math.min(
          (rect.width - pad * 2) / (bounds.maxX - bounds.minX),
          (rect.height - pad * 2) / (bounds.maxY - bounds.minY),
        ),
      )
      this.camera.scale = scale
      this.camera.x = pad - bounds.minX * scale + (rect.width - pad * 2 - (bounds.maxX - bounds.minX) * scale) / 2
      this.camera.y = pad - bounds.minY * scale + (rect.height - pad * 2 - (bounds.maxY - bounds.minY) * scale) / 2
      this.applyCamera()
    },

    handleWheel(e) {
      e.preventDefault()
      // Trackpad pinch arrives as ctrlKey+wheel; both it and a plain wheel mean zoom here, since
      // the canvas has no scrollable content of its own.
      const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015))
      this.zoomAt(this.camera.scale * factor, e.clientX, e.clientY)
    },

    // -- Dragging --

    handleDown(e) {
      if (e.button !== 0) return
      const node = e.target.closest("[data-node-id]")
      this.start = {x: e.clientX, y: e.clientY}
      this.moved = false

      if (node) {
        this.drag = {
          node,
          originX: parseFloat(node.style.left) || 0,
          originY: parseFloat(node.style.top) || 0,
        }
      } else {
        this.pan = {originX: this.camera.x, originY: this.camera.y}
        this.el.classList.add("is-panning")
      }
    },

    handleMove(e) {
      if (!this.drag && !this.pan) return
      const dx = e.clientX - this.start.x
      const dy = e.clientY - this.start.y

      if (!this.moved && Math.hypot(dx, dy) > 4) {
        this.moved = true
        if (this.drag) {
          this.paintDrag()
          this.pushEvent("drag_start", {})
        }
      }
      if (!this.moved) return

      if (this.pan) {
        this.camera.x = this.pan.originX + dx
        this.camera.y = this.pan.originY + dy
        this.applyCamera()
        return
      }

      // Pointer movement is in screen pixels; node positions are in world units.
      this.drag.node.style.left = `${this.drag.originX + dx / this.camera.scale}px`
      this.drag.node.style.top = `${this.drag.originY + dy / this.camera.scale}px`
      this.redraw()
    },

    handleUp() {
      this.el.classList.remove("is-panning")

      if (this.drag && this.moved) {
        this.suppressClick = true
        this.pushEvent("node_moved", {
          id: this.drag.node.dataset.nodeId,
          x: Math.round(parseFloat(this.drag.node.style.left)),
          y: Math.round(parseFloat(this.drag.node.style.top)),
        })
        this.pushEvent("drag_end", {})
      }

      this.drag = null
      this.pan = null
      this.moved = false
      this.dropTarget = null
      this.paintDrag()
    },

    // -- Redrawing wires and boxes, mirroring EvaWeb.Proto.Layout --

    redraw() {
      const nodes = {}
      this.el.querySelectorAll("[data-node-id]").forEach((node) => {
        nodes[node.dataset.nodeId] = {
          x: parseFloat(node.style.left) || 0,
          y: parseFloat(node.style.top) || 0,
          project: node.dataset.project,
          machine: node.dataset.machine,
        }
      })

      // Wires follow every node including the one in hand — a wire that let go of its TV mid-drag
      // would read as the connection being broken.
      this.el.querySelectorAll(".canvas-wire").forEach((path) => {
        const from = nodes[path.dataset.from]
        const to = nodes[path.dataset.to]
        if (from && to) path.setAttribute("d", this.wirePath(from, to))
      })

      // Boxes, on the other hand, are fitted as if the dragged session had already left. Its old
      // project visibly lets go of it, and the box it is about to land in is the one it is over
      // rather than one stretched around it. `EvaWeb.Proto.Layout.drop_target/4` excludes the same
      // node for the same reason, so what you see is what the drop resolves to.
      const held = this.drag && this.moved ? this.drag.node.dataset.nodeId : null
      const settled = Object.entries(nodes).filter(([id]) => id !== held)

      const projectRects = {}
      this.el.querySelectorAll('[data-box="project"]').forEach((box) => {
        const id = box.dataset.boxId
        const corners = settled
          .filter(([, n]) => n.project === id)
          .flatMap(([, n]) => [
            [n.x, n.y],
            [n.x + this.metrics.nodeW, n.y + this.metrics.nodeH],
          ])
        // An emptied project keeps whatever rect the server last gave it, so it stays somewhere you
        // can drop a session back into.
        const rect = corners.length ? this.bounds(corners, this.metrics.projectPad) : this.boxRect(box)
        projectRects[id] = {...rect, machine: box.dataset.machine}
        if (corners.length) this.setBox(box, rect)
      })

      this.el.querySelectorAll('[data-box="machine"]').forEach((box) => {
        const id = box.dataset.boxId
        const corners = Object.values(projectRects)
          .filter((r) => r.machine === id)
          .flatMap((r) => [
            [r.x, r.y - this.metrics.labelGap],
            [r.x + r.w, r.y + r.h],
          ])
        if (corners.length === 0) return
        this.setBox(box, this.bounds(corners, this.metrics.machinePad))
      })

      this.highlightTarget(held && nodes[held], held && nodes[held] && nodes[held].project, projectRects)
    },

    // The box the held session would land in: the smallest one containing its screen's midpoint,
    // ignoring the project it already belongs to since dropping there changes nothing.
    highlightTarget(node, ownProject, projectRects) {
      const x = node ? node.x + this.metrics.nodeW / 2 : null
      const y = node ? node.y + this.metrics.nodeH * 0.38 : null

      const hit = node
        ? Object.entries(projectRects)
            .filter(
              ([id, r]) =>
                id !== ownProject && x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h,
            )
            .sort(([, a], [, b]) => a.w * a.h - b.w * b.h)[0]
        : null

      this.dropTarget = hit ? hit[0] : null
      this.paintDrag()
    },

    // Kept separate from deciding the target so a server patch can restore the classes without
    // having to recompute anything.
    paintDrag() {
      this.el.querySelectorAll('[data-box="project"]').forEach((box) => {
        box.classList.toggle("is-drop-target", box.dataset.boxId === this.dropTarget)
      })
      this.el.querySelectorAll("[data-node-id]").forEach((node) => {
        node.classList.toggle(
          "is-dragging",
          !!this.drag && !!this.moved && node === this.drag.node,
        )
      })
    },

    bounds(corners, pad) {
      const xs = corners.map((c) => c[0])
      const ys = corners.map((c) => c[1])
      const minX = Math.min(...xs)
      const minY = Math.min(...ys)
      return {
        x: minX - pad,
        y: minY - pad,
        w: Math.max(...xs) - minX + pad * 2,
        h: Math.max(...ys) - minY + pad * 2,
      }
    },

    boxRect(box) {
      return {
        x: parseFloat(box.style.left) || 0,
        y: parseFloat(box.style.top) || 0,
        w: parseFloat(box.style.width) || 0,
        h: parseFloat(box.style.height) || 0,
      }
    },

    setBox(box, {x, y, w, h}) {
      box.style.left = `${x}px`
      box.style.top = `${y}px`
      box.style.width = `${w}px`
      box.style.height = `${h}px`
    },

    wirePath(from, to) {
      const {nodeW, nodeH} = this.metrics
      const y1 = from.y + nodeH * 0.38
      const y2 = to.y + nodeH * 0.38
      const x1 = to.x >= from.x ? from.x + nodeW : from.x
      const x2 = to.x >= from.x ? to.x : to.x + nodeW
      const bow = Math.max(60, Math.abs(x2 - x1) * 0.45)
      return `M ${x1} ${y1} C ${x1 + bow} ${y1}, ${x2 - bow} ${y2}, ${x2} ${y2}`
    },
  },

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
        }
      })
      this.el.addEventListener("input", () => this.grow())
      // Cleared from the server after the prompt is accepted. Clearing it on the form's own
      // submit event would race LiveView's serialization and send an empty message.
      this.handleEvent("chat:clear", () => this.reset())
      this.grow()
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

