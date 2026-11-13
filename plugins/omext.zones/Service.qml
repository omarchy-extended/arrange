import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons as Commons

// Zone picker for omext arrange (omarchy-extended). `omext-zone pick` (Super + Z)
// calls `pick <address>`: the window's screen gets an overlay; the bar button
// calls `pickOn <address> <screen>` for the screen it is on, the window (if any)
// going there. The overlay has with its zones where they are. Click one to snap the window there, or
// press on one and drag across others to span them; 1-9 snap from the keyboard,
// Esc closes. The row at the top switches the screen's zone set (omext-zone use);
// Edit and New there open the editor: click a zone to split it (Shift: across),
// drag a divider to resize, drag over zones to join them, and save under a name
// (omext-zone save; your own sets can be deleted again). Choose lets you pick
// which sets the row shows (omext-zone hide/show).
// While a floating window is dragged (hypr/zones-drag.lua calls dragStart/dragEnd), a
// snap bar with each screen's zones shows at its top: let go over a zone there
// and the window snaps into it, or over the strip below them to fill the screen.
// omext-zone does the placing; this file only draws `omext-zone list`.
Item {
  id: root

  property var shell: null

  readonly property string tool: Quickshell.env("HOME") + "/.local/bin/omext-zone"
  property string address: ""   // window being placed, "" for none
  property string screenName: "" // screen asked for, else the window's
  property bool shown: false
  property var data: null       // omext-zone list
  property var monitor: null    // its screen, from data
  property var picked: []       // zone indexes, in the order dragged over
  property int hovered: -1
  readonly property bool open: shown && monitor !== null
  readonly property color accent: Commons.Color.accent

  property bool choosing: false  // picking which sets the row shows

  // Editor: the set being made, as fractions of the free area.
  property bool editing: false
  property var draft: []
  property string original: ""  // the own set being changed, "" for a new one
  property string editError: ""
  property var line: null       // divider being dragged: { vertical, pos }
  property bool shiftDown: false
  property point pointer: Qt.point(-1, -1)
  readonly property real step: 1 / 48  // splits and dividers land on this grid
  readonly property real eps: 0.002

  // Snap bar, while a window is dragged.
  property string dragged: ""   // its address
  property var dragData: null   // omext-zone list, when the drag started
  property var hover: null      // { monitor, zone } under the pointer in a snap bar
  // Shift held while dragging: no bar, the zones over the whole screen, each
  // where it is. The window goes where it's dropped (on a line between zones:
  // across them).
  property bool dragWide: false
  // Shift let go of: the zones gone from view, what was pointed at kept, until
  // it's known whether that was a drop or the drag being called off.
  property bool dragHeld: false
  readonly property int wideReach: 36   // px on the screen, each side of a line between zones
  // A dock's place in that view: a strip along its edge of the screen (more
  // than one on an edge share it), [x, y, w, h] on the screen. A window dropped
  // there goes into the dock.
  // (As wide as a dock's own strip of icons at the screen's edge: the widest
  // dock's, the same for every dock, one that shows no strip too.)
  readonly property int wideDock: {
    var w = 36
    for (var d of (docksData && docksData.docks) || []) if (!d.off && Number(d.barWidth) > w) w = Number(d.barWidth)
    return w
  }
  function wideDockRect(m, d) {
    var same = sideDocks(m, d.edge), i = same.findIndex(o => o.id === d.id), n = Math.max(1, same.length), gap = 6
    var a = m.area
    if (d.edge === "left" || d.edge === "right") {
      var each = (a[3] - (n - 1) * gap) / n
      return [d.edge === "left" ? m.x : m.x + m.width - wideDock, a[1] + i * (each + gap), wideDock, each]
    }
    var wide = (a[2] - (n - 1) * gap) / n
    return [a[0] + i * (wide + gap), d.edge === "top" ? m.y : m.y + m.height - wideDock, wide, wideDock]
  }
  readonly property int barWidth: 300
  readonly property int barPad: 8
  readonly property int barGap: 12  // below the free area's top
  readonly property int fillHeight: 22  // the fill-the-screen strip under the zones
  // With omext docks installed (and on): the screen's docks under that, to drop
  // the window into one (omext-dock add <dock> --window).
  readonly property string docksTool: Quickshell.env("HOME") + "/.local/bin/omext-dock"
  property var docksData: null   // omext-dock list, when the drag started
  function docksFor(m) {
    if (!docksData || !docksData.docks || !m) return []
    var on = docksData.docks.filter(d => d.screen === m.name && !d.off)
    return on.map(d => {
      var edge = String(d.edge || "")
      var twin = on.some(o => o !== d && o.edge === d.edge)
      return { id: d.id, edge: edge, rect: d.rect || null, label: (edge.charAt(0).toUpperCase() + edge.slice(1)) + " dock" + (twin ? " (" + d.id + ")" : "") }
    })
  }

  // The titlebar button: a small map of every screen's zones at the pointer; a
  // click on a zone (or a screen's Fill screen) puts the window there.
  property string quickAddr: ""
  property string quickScreen: ""
  property point quickAt: Qt.point(0, 0)
  // Where the map opens: on the window's screen, under the pointer (the
  // titlebar's button), or on another screen, above a point there (a taskbar's
  // icon: the map stands on the bar, clear of it).
  property string quickOn: ""
  property bool quickAbove: false
  property string quickPinWord: ""   // from a taskbar's icon: "pin" or "unpin" (what the Pin line does), else none
  property var quickData: null
  property var quickHover: null    // { monitor, zone } under the pointer; zone -1 is Fill screen

  function quick(addr, screen, x, y) {
    close()
    quickAddr = addr.startsWith("0x") ? addr : "0x" + addr
    quickScreen = screen
    quickOn = screen
    quickAbove = false
    quickPinWord = ""
    quickAt = Qt.point(parseInt(x) || 0, parseInt(y) || 0)
    quickHover = null
    quickData = null
    docksData = null
    quickListProc.running = false
    quickListProc.running = true
    docksListProc.running = false
    docksListProc.running = true
  }
  function quickOver(addr, screen, on, x, y) {
    quick(addr, screen, x, y)
    quickOn = on || screen
    quickAbove = true
  }
  function quickPin(addr, screen, on, x, y, word) {
    quickOver(addr, screen, on, x, y)
    quickPinWord = word === "pin" || word === "unpin" ? word : ""
  }
  function quickDock(dock) {
    if (quickAddr) Quickshell.execDetached([docksTool, "send", "--dock", dock, "--window", quickAddr])
    closeQuick()
  }

  function closeQuick() {
    quickAddr = ""
    quickData = null
    quickHover = null
    if (dragged === "") docksData = null
  }

  // zone: one zone's number (from 0), several ([0, 1]: across them), or -1 (the whole screen).
  function quickSnap(screen, zone) {
    var m = quickData ? quickData.monitors.find(x => x.name === screen) : null
    if (m && quickAddr) {
      var picks = Array.isArray(zone) ? zone : zone >= 0 ? [zone] : m.zones.map((z, i) => i)
      var zones = picks.map(i => i + 1).join(",")
      // ... and in front, with the focus: picked from a taskbar, it may have
      // been behind the others (or on another screen).
      Quickshell.execDetached(["bash", "-c", '"$0" snap "$1" --window "$2" --monitor "$3"; '
        + 'hyprctl dispatch "hl.dsp.focus({ window = \'address:$2\' })" >/dev/null; '
        + 'hyprctl dispatch "hl.dsp.window.alter_zorder({ mode = \'top\', window = \'address:$2\' })" >/dev/null',
        tool, zones, quickAddr, screen])
    }
    closeQuick()
  }

  function pick(addr) { pickOn(addr, "") }

  // Straight into the editor on a screen (the Arrange menu's Edit and New):
  // "copy" edits its set (a copy of a built-in one), "new" starts a blank one.
  property string editAfter: ""
  function editOn(screen, how) {
    pickOn("", screen)
    editAfter = how
  }

  function pickOn(addr, screen) {
    address = addr
    screenName = screen
    shown = true
    monitor = null
    picked = []
    hovered = -1
    listProc.running = false
    listProc.running = true
  }

  function close() {
    editing = false
    choosing = false
    shown = false
    address = ""
    screenName = ""
    monitor = null
    picked = []
    hovered = -1
  }

  function load(text) {
    try { data = JSON.parse(text) } catch (e) { close(); return }
    // The window's screen; clientsProc tells which.
    clientsProc.running = false
    clientsProc.running = true
  }

  function placeOn(text) {
    var c = null
    try { c = JSON.parse(text).find(x => x.address === root.address) } catch (e) {}
    if (!data || (!c && !screenName)) { close(); return }
    monitor = data.monitors.find(m => screenName ? m.name === screenName : m.id === c.monitor) || null
    if (!monitor) { editAfter = ""; close(); return }
    if (editAfter) { var how = editAfter; editAfter = ""; edit(how === "new") }
  }

  function snap(indexes) {
    if (!indexes.length || !address) { close(); return }
    var n = indexes.map(i => i + 1).sort((a, b) => a - b)
    Quickshell.execDetached([tool, "snap", n.join(","), "--window", address, "--monitor", monitor.name])
    close()
  }

  function isHidden(name) {
    return !!(data && data.hidden && data.hidden.indexOf(name) >= 0)
  }

  // Your own sets, or the built-in ones: every one while choosing, else those
  // not hidden (and the one in use).
  function rowSets(own) {
    if (!data || !data.sets) return []
    return Object.keys(data.sets).filter(n => isCustom(n) === own
      && (choosing || !isHidden(n) || (monitor && monitor.set === n)))
  }

  function toggleHidden(name) {
    useProc.command = [tool, isHidden(name) ? "show" : "hide", name]
    useProc.running = true
  }

  function useSet(name) {
    if (!monitor || name === monitor.set) return
    useProc.command = [tool, "use", name, "--monitor", monitor.name]
    useProc.running = true
  }

  // Editor --------------------------------------------------------------------

  function isCustom(name) {
    return !!(data && data.custom && data.custom.indexOf(name) >= 0)
  }

  function edit(fresh) {
    if (!monitor) return
    draft = fresh ? [[0, 0, 1, 1]] : data.sets[monitor.set].map(z => z.slice())
    original = !fresh && isCustom(monitor.set) ? monitor.set : ""
    nameInput.text = original
    editError = ""
    picked = []
    line = null
    editing = true
    if (original) focusTaker.forceActiveFocus()
    else nameInput.forceActiveFocus()
  }

  function save() {
    var name = nameInput.text.trim()
    if (!name) { editError = "Give the set a name"; nameInput.forceActiveFocus(); return }
    var zs = draft.map(z => z.map(v => Math.round(v * 10000) / 10000))
    saveProc.command = [tool, "save", name, JSON.stringify(zs), "--monitor", monitor.name]
    saveProc.running = true
  }

  function stopEditing() {
    editing = false
    line = null
    picked = []
    focusTaker.forceActiveFocus()
  }

  function remove() {
    if (!original) return
    saveProc.command = [tool, "delete", original]
    saveProc.running = true
  }

  // Free area of the screen, in overlay coordinates.
  function areaBox() {
    return [monitor.area[0] - monitor.x, monitor.area[1] - monitor.y, monitor.area[2], monitor.area[3]]
  }

  function toFrac(x, y) {
    var a = areaBox()
    return [(x - a[0]) / a[2], (y - a[1]) / a[3]]
  }

  function onGrid(v) { return Math.round(v / step) * step }

  function draftAt(x, y) {
    var f = toFrac(x, y)
    for (var i = 0; i < draft.length; i++) {
      var z = draft[i]
      if (f[0] >= z[0] && f[0] < z[0] + z[2] && f[1] >= z[1] && f[1] < z[1] + z[3]) return i
    }
    return -1
  }

  // The divider under the pointer, if any: an inner zone edge within a few pixels.
  function dividerAt(x, y) {
    var a = areaBox(), f = toFrac(x, y)
    var tx = 6 / a[2], ty = 6 / a[3]
    for (var z of draft) {
      var inY = f[1] >= z[1] && f[1] <= z[1] + z[3], inX = f[0] >= z[0] && f[0] <= z[0] + z[2]
      for (var e of [z[0], z[0] + z[2]])
        if (inY && e > eps && e < 1 - eps && Math.abs(f[0] - e) < tx) return { vertical: true, pos: e }
      for (var e2 of [z[1], z[1] + z[3]])
        if (inX && e2 > eps && e2 < 1 - eps && Math.abs(f[1] - e2) < ty) return { vertical: false, pos: e2 }
    }
    return null
  }

  // Where a click would split the zone under the pointer: [zone, vertical, pos], or null.
  function splitAt(x, y, across) {
    var i = draftAt(x, y)
    if (i < 0) return null
    var z = draft[i], f = toFrac(x, y), vertical = !across
    var start = vertical ? z[0] : z[1], size = vertical ? z[2] : z[3]
    var pos = Math.min(Math.max(onGrid(vertical ? f[0] : f[1]), start + step), start + size - step)
    if (size < 2 * step - eps) return null
    return [i, vertical, pos]
  }

  function split(x, y, across) {
    var s = splitAt(x, y, across)
    if (!s) return
    var z = draft[s[0]], next = draft.slice()
    if (s[1]) next.splice(s[0], 1, [z[0], z[1], s[2] - z[0], z[3]], [s[2], z[1], z[0] + z[2] - s[2], z[3]])
    else next.splice(s[0], 1, [z[0], z[1], z[2], s[2] - z[1]], [z[0], s[2], z[2], z[1] + z[3] - s[2]])
    draft = next
  }

  // Joined only when together they make a whole rectangle.
  function join(indexes) {
    var zs = indexes.map(i => draft[i])
    var x = Math.min(...zs.map(z => z[0])), y = Math.min(...zs.map(z => z[1]))
    var w = Math.max(...zs.map(z => z[0] + z[2])) - x, h = Math.max(...zs.map(z => z[1] + z[3])) - y
    var covered = zs.reduce((sum, z) => sum + z[2] * z[3], 0)
    if (Math.abs(covered - w * h) > 0.0005) { editError = "Those zones don't make a rectangle together"; return }
    var next = draft.filter((z, i) => indexes.indexOf(i) < 0)
    next.push([x, y, w, h])
    // Reading order: rows, then left to right.
    next.sort((a, b) => Math.abs(a[1] - b[1]) > eps ? a[1] - b[1] : a[0] - b[0])
    draft = next
    editError = ""
  }

  function moveDivider(x, y) {
    var f = toFrac(x, y), v = line.vertical, at = line.pos
    var lo = 0, hi = 1
    for (var z of draft) {
      var start = v ? z[0] : z[1], size = v ? z[2] : z[3]
      if (Math.abs(start - at) < eps) hi = Math.min(hi, start + size - step)
      if (Math.abs(start + size - at) < eps) lo = Math.max(lo, start + step)
    }
    var pos = Math.min(Math.max(onGrid(v ? f[0] : f[1]), lo), hi)
    if (Math.abs(pos - at) < eps) return
    draft = draft.map(z => {
      var n = z.slice(), i = v ? 0 : 1
      if (Math.abs(z[i] - at) < eps) { n[i] = pos; n[i + 2] = z[i] + z[i + 2] - pos }
      else if (Math.abs(z[i] + z[i + 2] - at) < eps) n[i + 2] = pos - z[i]
      return n
    })
    line = { vertical: v, pos: pos }
  }

  function zoneAt(x, y) {
    if (!monitor) return -1
    for (var i = 0; i < monitor.zones.length; i++) {
      var z = monitor.zones[i]
      var zx = z[0] - monitor.x, zy = z[1] - monitor.y
      if (x >= zx && x < zx + z[2] && y >= zy && y < zy + z[3]) return i
    }
    return -1
  }

  function dragStart(addr) {
    dragged = addr.startsWith("0x") ? addr : "0x" + addr
    dragWide = false
    dragHeld = false
    hover = null
    docksData = null
    dragListProc.running = false
    dragListProc.running = true
    docksListProc.running = false
    docksListProc.running = true
  }

  function dragEnd() {
    if (dragged !== "" && hover && hover.dock) {
      // (Dropped there: a closed dock stays closed, the window in it.)
      Quickshell.execDetached([docksTool, "send", "--quiet", "--dock", hover.dock, "--window", dragged])
    } else if (dragged !== "" && hover) {
      // Filling is all the screen's zones at once: the whole free area.
      var m = dragData ? dragData.monitors.find(x => x.name === hover.monitor) : null
      var zones = hover.zone >= 0 ? (hover.zones || [hover.zone]).map(i => i + 1).join(",") : m ? m.zones.map((z, i) => i + 1).join(",") : ""
      if (zones) Quickshell.execDetached([tool, "snap", zones, "--window", dragged, "--monitor", hover.monitor])
    }
    dragged = ""
    dragWide = false
    dragHeld = false
    dragData = null
    docksData = null
    hover = null
  }

  // Size of a screen's snap bar, and where it is on the screen (top centre).
  // The screen's docks sit around the zone map where they are on the screen: a
  // strip on its left, right, top or bottom side.
  readonly property int dockWidth: 22
  function sideDocks(m, edge) { return docksFor(m).filter(d => d.edge === edge) }
  function inset(m, edge) { return sideDocks(m, edge).length ? dockWidth + 4 : 0 }
  // (bw: the width it's drawn in, the snap bar's unless said: the titlebar map's tiles)
  function mapWidth(m, bw) { return (bw || barWidth) - 2 * barPad - inset(m, "left") - inset(m, "right") }
  function zonesHeight(m, bw) { return Math.round(mapWidth(m, bw) * m.area[3] / m.area[2]) }
  function mapHeight(m, bw) { return inset(m, "top") + zonesHeight(m, bw) + inset(m, "bottom") }
  function barHeight(m) {
    return mapHeight(m) + 3 * barPad + fillHeight
  }
  function barRect(m) {
    return [m.x + Math.round((m.width - barWidth) / 2), m.area[1] + barGap, barWidth, barHeight(m)]
  }
  // A zone drawn small inside the bar, relative to the bar.
  function miniZone(m, z) {
    var s = mapWidth(m) / m.area[2]
    return [barPad + inset(m, "left") + (z[0] - m.area[0]) * s, barPad + inset(m, "top") + (z[1] - m.area[1]) * s, z[2] * s, z[3] * s]
  }
  // The fill strip, relative to the bar.
  function fillStrip(m) {
    return [barPad, mapHeight(m) + 2 * barPad, barWidth - 2 * barPad, fillHeight]
  }
  // A dock's strip beside the zone map (more than one on a side share it).
  function dockStrip(m, d, bw) {
    bw = bw || barWidth
    var same = sideDocks(m, d.edge), i = same.findIndex(o => o.id === d.id), n = same.length, gap = 4
    var x0 = barPad + inset(m, "left"), y0 = barPad + inset(m, "top"), w = mapWidth(m, bw), h = zonesHeight(m, bw)
    if (d.edge === "left" || d.edge === "right") {
      var each = (h - (n - 1) * gap) / n
      return [d.edge === "left" ? barPad : bw - barPad - dockWidth, y0 + i * (each + gap), dockWidth, each]
    }
    var wide = (w - (n - 1) * gap) / n
    return [x0 + i * (wide + gap), d.edge === "top" ? barPad : y0 + h + 4, wide, dockWidth]
  }

  // The zones a point takes (their numbers, from 0): the one it's in, and with
  // it any other it's within `r` of. On the line between two zones that's both;
  // where four meet, all four: a window dropped there covers them together.
  // (x, y) and r are in the screen's own pixels, as the zones are.
  readonly property int spanReach: 7   // px in the map, each side of a line between zones
  function zonesNear(m, x, y, r) {
    var out = []
    for (var i = 0; i < m.zones.length; i++) {
      var z = m.zones[i]
      if (x >= z[0] - r && x < z[0] + z[2] + r && y >= z[1] - r && y < z[1] + z[3] + r) out.push(i)
    }
    return out
  }
  function hasZone(h, monitor, index) {
    if (!h || h.monitor !== monitor) return false
    return h.zone === -1 || (h.zones ? h.zones.indexOf(index) >= 0 : h.zone === index)
  }

  function track(text) {
    if (!dragData) return
    var p = null
    try { p = JSON.parse(text) } catch (e) { return }
    var found = null
    if (dragHeld) return
    if (dragWide) {
      // On the screen itself: the zones where they are.
      for (var w of dragData.monitors) {
        if (p.x < w.x || p.x >= w.x + w.width || p.y < w.y || p.y >= w.y + w.height) continue
        var on = zonesNear(w, p.x, p.y, wideReach)
        if (on.length) found = { monitor: w.name, zone: on[0], zones: on }
        for (var k of docksFor(w)) {   // a dock's strip, over the zones' edge
          var r = wideDockRect(w, k)
          if (p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3]) found = { monitor: w.name, zone: -2, dock: k.id }
        }
      }
      if (JSON.stringify(found) !== JSON.stringify(hover)) hover = found
      return
    }
    for (var m of dragData.monitors) {
      var b = barRect(m)
      if (p.x < b[0] || p.x >= b[0] + b[2] || p.y < b[1] || p.y >= b[1] + b[3]) continue
      var x = p.x - b[0], y = p.y - b[1]
      // (In the bar's map: its scale, and where the map starts in the bar.)
      var s = mapWidth(m) / m.area[2]
      var near = zonesNear(m, m.area[0] + (x - barPad - inset(m, "left")) / s, m.area[1] + (y - barPad - inset(m, "top")) / s, spanReach / s)
      if (near.length) found = { monitor: m.name, zone: near[0], zones: near }
      var f = fillStrip(m)
      if (x >= f[0] && x < f[0] + f[2] && y >= f[1] - 4 && y < f[1] + f[3]) found = { monitor: m.name, zone: -1 }
      for (var d of docksFor(m)) {
        var r = dockStrip(m, d)
        if (x >= r[0] - 3 && x < r[0] + r[2] + 3 && y >= r[1] - 3 && y < r[1] + r[3] + 3) found = { monitor: m.name, zone: -2, dock: d.id }
      }
    }
    if (JSON.stringify(found) !== JSON.stringify(hover)) hover = found
  }

  function screenFor(m) {
    if (!m) return null
    return Quickshell.screens.find(s => s.name === m.name) || null
  }

  component Btn: Rectangle {
    id: btn
    property string label
    property bool small: false
    signal clicked()
    width: small ? 84 : Math.max(64, btnText.implicitWidth + 20)
    height: small ? 22 : 30
    radius: 6
    color: btnHit.containsMouse ? Commons.Util.alpha(root.accent, 0.3) : Commons.Util.alpha(Commons.Color.foreground, 0.08)
    Text {
      id: btnText
      anchors.centerIn: parent
      text: btn.label
      color: Commons.Color.popups.text
      font.family: Commons.Style.font.family
      font.pixelSize: btn.small ? 11 : 12
    }
    MouseArea { id: btnHit; anchors.fill: parent; hoverEnabled: true; onClicked: btn.clicked() }
  }

  // A zone set in the picker's row: click to use it (or, while choosing, to hide or show it).
  component SetTile: Rectangle {
    id: tile
    property string name
    property bool small: false
    readonly property bool current: root.monitor !== null && root.monitor.set === name
    readonly property bool off: root.isHidden(name)
    width: small ? 60 : 84
    height: small ? 52 : 72
    radius: 6
    opacity: root.choosing && off ? 0.4 : 1
    color: tileHit.containsMouse ? Commons.Util.alpha(Commons.Color.foreground, 0.1) : "transparent"
    border.width: current ? 2 : 0
    border.color: root.accent
    Item {
      id: preview
      anchors.horizontalCenter: parent.horizontalCenter
      y: tile.small ? 6 : 8
      width: tile.small ? 44 : 64
      height: tile.small ? 25 : 36
      Repeater {
        model: root.data && root.data.sets[tile.name] ? root.data.sets[tile.name] : []
        Rectangle {
          required property var modelData
          x: modelData[0] * preview.width + 1
          y: modelData[1] * preview.height + 1
          width: modelData[2] * preview.width - 2
          height: modelData[3] * preview.height - 2
          radius: 2
          color: Commons.Util.alpha(tile.current ? root.accent : Commons.Color.foreground, 0.5)
        }
      }
    }
    Text {
      anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: tile.small ? 4 : 6 }
      width: parent.width - 6
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: tile.name
      color: Commons.Color.popups.text
      font.family: Commons.Style.font.family
      font.pixelSize: tile.small ? 9 : 11
    }
    MouseArea {
      id: tileHit
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.choosing ? root.toggleHidden(tile.name) : root.useSet(tile.name)
    }
    // Shown or not, while choosing.
    Text {
      visible: root.choosing
      anchors { right: parent.right; top: parent.top; margins: 2 }
      text: tile.off ? "\u{F0209}" : "\u{F0208}"
      color: tile.off ? Commons.Color.popups.text : root.accent
      font.pixelSize: tile.small ? 10 : 13
    }
  }

  // Escape (omext core's bind): the zone map goes.
  GlobalShortcut { appid: "omext"; name: "escape-zones"; description: "Close the zone map"; onPressed: root.closeQuick() }

  IpcHandler {
    target: "omext.zones"
    function pick(address: string): void { root.pick(address) }
    function pickOn(address: string, screen: string): void { root.pickOn(address, screen) }
    function editOn(screen: string, how: string): void { root.editOn(screen, how) }
    function close(): void { root.close(); root.closeQuick() }
    function dragStart(address: string): void { root.dragStart(address) }
    // ... with Shift held already: the zones over the whole screen from the start.
    function dragStartWide(address: string): void { root.dragStart(address); root.dragWide = true }
    function dragEnd(): void { root.dragEnd() }
    // Called off (Shift let go of with the button held): the window goes nowhere.
    function dragCancel(): void { root.hover = null; root.dragEnd() }
    function dragWide(on: string): void { if (root.dragged !== "") { root.dragHeld = false; root.hover = null; root.dragWide = on === "on" } }
    function dragHold(): void { if (root.dragged !== "") root.dragHeld = true }
    function quick(address: string, screen: string, x: string, y: string): void { root.quick(address, screen, x, y) }
    // The map on screen `on`, standing on the point (x, y) there: for a window on `screen`.
    function quickOver(address: string, screen: string, on: string, x: string, y: string): void { root.quickOver(address, screen, on, x, y) }
    function quickPin(address: string, screen: string, on: string, x: string, y: string, word: string): void { root.quickPin(address, screen, on, x, y, word) }
  }

  Process {
    id: quickListProc
    command: [root.tool, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.quickAddr === "") return
        try { root.quickData = JSON.parse(text) } catch (e) { root.closeQuick() }
      }
    }
  }

  // The quick map: over the whole screen it opens on, so a click beside it
  // closes it. It shows every screen's zones side by side (left to right as the
  // screens are); a click puts the window in that zone on that screen.
  PanelWindow {
    id: quickPop
    readonly property var mon: root.quickData && root.quickAddr ? root.quickData.monitors.find(m => m.name === root.quickScreen) || null : null
    readonly property var mons: root.quickData && root.quickAddr ? root.quickData.monitors.slice().sort((a, b) => a.x - b.x || a.y - b.y) : []
    readonly property int tileW: 240
    readonly property int pad: 8
    readonly property int labelH: 18
    // A small screen is drawn smaller than a large one, by a part of how much
    // smaller it is (sizeHint: 0.3, about a third of the real difference): enough
    // to tell them apart, with zones still large enough to click. The widest is
    // tileW wide. They stand on one line: their bottoms level.
    readonly property real sizeHint: 0.3
    readonly property real widest: mons.reduce((w, m) => Math.max(w, m.area[2]), 1)
    function tileWOf(m) { return Math.round(tileW * (1 - sizeHint * (1 - m.area[2] / widest))) }
    readonly property int mapH: mons.reduce((h, m) => Math.max(h, root.mapHeight(m, tileWOf(m))), 0)
    function tileH(m) { return mapH + 3 * pad + root.fillHeight + labelH }
    readonly property int boxH: mons.length ? tileH(mons[0]) : 0
    readonly property var popMon: root.quickData && root.quickAddr ? root.quickData.monitors.find(m => m.name === root.quickOn) || mon : null
    screen: root.screenFor(popMon)
    visible: mon !== null && popMon !== null && Quickshell.screens.some(s => s.name === popMon.name)
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omext-zones-quick"
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: root.closeQuick() }
    Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: root.closeQuick() }

    Rectangle {
      id: quickBox
      // Under the pointer (or standing on the point given), kept on the screen.
      x: quickPop.popMon ? Math.max(8, Math.min(quickPop.popMon.width - width - 8, root.quickAt.x - quickPop.popMon.x - width / 2)) : 0
      y: quickPop.popMon ? Math.max(8, Math.min(quickPop.popMon.height - height - 8,
           root.quickAt.y - quickPop.popMon.y + (root.quickAbove ? -height - 8 : 12))) : 0
      readonly property int pinH: root.quickAbove && root.quickPinWord !== "" ? 18 + quickPop.pad / 2 : 0
      width: quickRow.implicitWidth + 2 * quickPop.pad
      height: quickPop.boxH + quickPop.pad + (root.quickAbove ? 18 + quickPop.pad : 0) + pinH
      radius: 10
      color: Commons.Util.alpha(Commons.Color.popups.background, 0.96)
      border.color: Commons.Util.alpha(root.accent, 0.6)
      // (A click between the tiles isn't one beside the map. What's pointed at
      // is said by each tile as the pointer comes onto it and leaves it: the
      // box's own "left" used to arrive after a tile's "entered" and undo it.)
      MouseArea { anchors.fill: parent }

      Row {
        id: quickRow
        x: quickPop.pad
        y: quickPop.pad / 2
        spacing: quickPop.pad
        Repeater {
          model: quickPop.mons
          Item {
            id: tile
            required property var modelData
            readonly property var m: modelData
            readonly property int w: quickPop.tileWOf(m)
            readonly property real s: root.mapWidth(m, w) / m.area[2]
            readonly property real mapH: quickPop.mapH
            readonly property real zonesH: root.zonesHeight(m, w)
            readonly property real tall: 1   // (its own shape)
            // Down onto the line the screens stand on.
            readonly property real down: mapH - root.mapHeight(m, w)
            readonly property real insetLeft: root.inset(m, "left")
            readonly property real insetTop: root.inset(m, "top")
            width: w
            height: quickPop.tileH(m)

            Text {
              x: quickPop.pad
              y: tile.down   // with its screen: right above it, wherever it stands
              height: quickPop.labelH
              verticalAlignment: Text.AlignVCenter
              width: parent.width - 2 * quickPop.pad
              elide: Text.ElideRight
              // The window's own screen first in brightness.
              text: (tile.m.description || tile.m.name).split(/\s+/)[0] + (tile.m.name === root.quickScreen ? "  • this window" : "")
              color: Commons.Util.alpha(Commons.Color.popups.text, tile.m.name === root.quickScreen ? 0.9 : 0.55)
              font.family: Commons.Style.font.family
              font.pixelSize: 11
            }

            Repeater {
              model: tile.m.zones
              Rectangle {
                required property var modelData
                required property int index
                readonly property bool lit: root.hasZone(root.quickHover, tile.m.name, index)
                x: quickPop.pad + tile.insetLeft + (modelData[0] - tile.m.area[0]) * tile.s + 2
                y: quickPop.labelH + quickPop.pad + tile.insetTop + tile.down + (modelData[1] - tile.m.area[1]) * tile.s * tile.tall + 2
                width: modelData[2] * tile.s - 4
                height: modelData[3] * tile.s * tile.tall - 4
                radius: 5
                color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
                border.width: lit ? 2 : 1
                border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
                Text {
                  anchors.centerIn: parent
                  text: index + 1
                  color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.6)
                  font.family: Commons.Style.font.family
                  font.pixelSize: Math.min(parent.height, parent.width) / 3
                  font.bold: true
                }
                MouseArea {
                  id: zoneHit
                  anchors.fill: parent
                  anchors.margins: -2   // up to the next zone: no dead line between them
                  hoverEnabled: true
                  // Near a line between zones: those zones together.
                  function here(mx, my) {
                    var z = modelData
                    return root.zonesNear(tile.m, z[0] + mx / tile.s, z[1] + my / (tile.s * tile.tall), root.spanReach / tile.s)   // (this area starts at the zone's own edge)
                  }
                  function point(mx, my) {
                    var near = here(mx, my)
                    if (near.indexOf(index) < 0) near = [index]
                    var h = root.quickHover
                    if (!h || h.monitor !== tile.m.name || JSON.stringify(h.zones) !== JSON.stringify(near))
                      root.quickHover = { monitor: tile.m.name, zone: index, zones: near }
                  }
                  onPositionChanged: function(mouse) { point(mouse.x, mouse.y) }
                  onContainsMouseChanged: {
                    var h = root.quickHover
                    if (containsMouse) point(mouseX, mouseY)
                    else if (h && h.monitor === tile.m.name && h.zone === index) root.quickHover = null
                  }
                  onClicked: function(mouse) {
                    var near = here(mouse.x, mouse.y)
                    root.quickSnap(tile.m.name, near.indexOf(index) >= 0 && near.length > 1 ? near : index)
                  }
                }
              }
            }

            Rectangle {
              readonly property bool lit: root.quickHover !== null && root.quickHover.monitor === tile.m.name && root.quickHover.zone === -1
              x: quickPop.pad + 2
              y: quickPop.labelH + 2 * quickPop.pad + tile.mapH
              width: tile.w - 2 * quickPop.pad - 4
              height: root.fillHeight
              radius: 5
              color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
              border.width: lit ? 2 : 1
              border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
              Text {
                anchors.centerIn: parent
                text: tile.w < 170 ? "\u{F0293}  Fill" : "\u{F0293}  Fill screen"
                color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
                font.family: Commons.Style.font.family
                font.pixelSize: 11
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onContainsMouseChanged: {
                  var h = root.quickHover
                  if (containsMouse) root.quickHover = { monitor: tile.m.name, zone: -1 }
                  else if (h && h.monitor === tile.m.name && h.zone === -1) root.quickHover = null
                }
                onClicked: root.quickSnap(tile.m.name, -1)
              }
            }

            // The screen's docks, on their sides of the map: a click sends it there.
            Repeater {
              model: root.docksFor(tile.m)
              Rectangle {
                id: qDock
                required property var modelData
                readonly property var r: root.dockStrip(tile.m, modelData, tile.w)
                readonly property bool upright: modelData.edge === "left" || modelData.edge === "right"
                readonly property bool lit: root.quickHover !== null && root.quickHover.dock === modelData.id
                // (Drawn as tall as the map is: a side dock stretched with it, a
                // bottom one below it.)
                readonly property real top0: root.barPad + root.inset(tile.m, "top")
                x: r[0] + 2
                y: quickPop.labelH + 2 + (upright ? top0 + tile.down + (r[1] - top0) * tile.tall
                                          : modelData.edge === "top" ? r[1] + tile.down : top0 + tile.down + tile.zonesH * tile.tall + 4)
                width: r[2] - 4; height: (upright ? r[3] * tile.tall : r[3]) - 4
                radius: 5
                color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
                border.width: lit ? 2 : 1
                border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
                Text {
                  anchors.centerIn: parent
                  width: (qDock.upright ? parent.height : parent.width) - 8
                  rotation: modelData.edge === "left" ? -90 : modelData.edge === "right" ? 90 : 0
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  // (A small screen's strip has room for its mark alone.)
                  text: (qDock.upright ? qDock.height : qDock.width) < 70 ? "\u{F10A9}" : "\u{F10A9}  " + modelData.label
                  color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
                  font.family: Commons.Style.font.family
                  font.pixelSize: 11
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onContainsMouseChanged: {
                    var h = root.quickHover
                    if (containsMouse) root.quickHover = { monitor: tile.m.name, zone: -2, dock: modelData.id }
                    else if (h && h.dock === modelData.id) root.quickHover = null
                  }
                  onClicked: root.quickDock(modelData.id)
                }
              }
            }
          }
        }
      }

      // Opened from a taskbar's icon (not the window's own titlebar, which
      // has its buttons): the app can be quit from here too.
      // ... and its app pinned to the taskbar, or taken off it.
      Rectangle {
        id: quickPinLine
        visible: root.quickAbove && root.quickPinWord !== ""
        readonly property bool lit: quickPinHit.containsMouse
        x: quickPop.pad
        y: quickPop.boxH + quickPop.pad / 2
        width: quickBox.width - 2 * quickPop.pad
        height: 18
        radius: 5
        color: lit ? Commons.Util.alpha(root.accent, 0.45) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
        border.width: 1
        border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
        Text {
          anchors.centerIn: parent
          text: root.quickPinWord === "unpin" ? "\u{F0404}  Unpin from taskbar" : "\u{F0403}  Pin to taskbar"
          color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
          font.family: Commons.Style.font.family
          font.pixelSize: 10
        }
        MouseArea {
          id: quickPinHit
          anchors.fill: parent
          hoverEnabled: true
          onClicked: {
            if (root.quickAddr) Quickshell.execDetached(["omarchy-shell", "-q", "omext.taskbar", "pin", root.quickAddr])
            root.closeQuick()
          }
        }
      }
      Rectangle {
        id: quickClose
        visible: root.quickAbove
        readonly property bool lit: quickCloseHit.containsMouse
        x: quickPop.pad
        y: quickPop.boxH + quickPop.pad / 2 + (quickPinLine.visible ? 18 + quickPop.pad / 2 : 0)
        width: quickBox.width - 2 * quickPop.pad
        height: 18
        radius: 5
        color: lit ? Commons.Util.alpha(Commons.Color.urgent, 0.55) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
        border.width: 1
        border.color: Commons.Util.alpha(lit ? Commons.Color.urgent : root.accent, lit ? 1 : 0.4)
        Text {
          anchors.centerIn: parent
          text: "\u{F0156}  Quit app"
          color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
          font.family: Commons.Style.font.family
          font.pixelSize: 10
        }
        MouseArea {
          id: quickCloseHit
          anchors.fill: parent
          hoverEnabled: true
          onClicked: {
            // Every window of the app is asked to close, as its own Quit would (nothing is killed).
            if (root.quickAddr) Quickshell.execDetached(["bash", "-c",
              'c=$(hyprctl clients -j); cls=$(jq -r --arg a "$0" \'.[] | select(.address == $a) | .class\' <<<"$c"); [ -n "$cls" ] || exit 0; '
              + 'jq -r --arg c "$cls" \'.[] | select(.class == $c) | .address\' <<<"$c" | while read -r a; do '
              + 'hyprctl dispatch "hl.dsp.window.close({ window = \'address:$a\' })" >/dev/null; done', root.quickAddr])
            root.closeQuick()
          }
        }
      }
    }
  }

  Process {
    id: dragListProc
    command: [root.tool, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.dragged === "") return
        try { root.dragData = JSON.parse(text) } catch (e) {}
      }
    }
  }

  Process {
    id: docksListProc
    command: ["bash", "-c", '[ -x "$0" ] && "$0" enabled && "$0" list', root.docksTool]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.dragged === "" && root.quickAddr === "") return
        try { root.docksData = JSON.parse(text) } catch (e) { root.docksData = null }
      }
    }
  }

  // Where the pointer is, while dragging.
  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos", "-j"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.track(text) }
  }

  Timer {
    interval: 40
    repeat: true
    running: root.dragData !== null
    onTriggered: if (!cursorProc.running) cursorProc.running = true
  }

  // The zones over the whole screen (Shift held while dragging): each where it
  // is, the one under the pointer lit. The pointer goes through: the drag
  // carries on underneath.
  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: wideZones
      required property var modelData
      readonly property var mon: root.dragData ? root.dragData.monitors.find(m => m.name === modelData.name) || null : null
      screen: modelData
      visible: mon !== null && root.dragWide && !root.dragHeld
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      mask: Region {}
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "omext-zones-wide"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Repeater {
        model: wideZones.mon ? wideZones.mon.zones : []
        Rectangle {
          required property var modelData
          required property int index
          readonly property bool lit: root.hasZone(root.hover, wideZones.mon.name, index)
          x: modelData[0] - wideZones.mon.x + 3
          y: modelData[1] - wideZones.mon.y + 3
          width: modelData[2] - 6
          height: modelData[3] - 6
          radius: 12
          color: lit ? Commons.Util.alpha(root.accent, 0.38) : Commons.Util.alpha(Commons.Color.popups.background, 0.28)
          border.width: lit ? 3 : 2
          border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.55)
          Behavior on color { ColorAnimation { duration: 90 } }
          Text {
            anchors.centerIn: parent
            text: index + 1
            color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 0.95 : 0.45)
            font.family: Commons.Style.font.family
            font.pixelSize: Math.max(28, Math.min(parent.height, parent.width) / 5)
            font.bold: true
          }
        }
      }

      // The screen's docks, along their edges.
      Repeater {
        model: wideZones.mon ? root.docksFor(wideZones.mon) : []
        Rectangle {
          id: wDock
          required property var modelData
          readonly property var r: root.wideDockRect(wideZones.mon, modelData)
          readonly property bool upright: modelData.edge === "left" || modelData.edge === "right"
          readonly property bool lit: root.hover !== null && root.hover.dock === modelData.id
          x: r[0] - wideZones.mon.x + 3
          y: r[1] - wideZones.mon.y + 3
          width: r[2] - 6
          height: r[3] - 6
          radius: 8
          color: lit ? Commons.Util.alpha(root.accent, 0.5) : Commons.Util.alpha(Commons.Color.popups.background, 0.72)
          border.width: lit ? 3 : 2
          border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.55)
          Behavior on color { ColorAnimation { duration: 90 } }
          Text {
            anchors.centerIn: parent
            width: (wDock.upright ? parent.height : parent.width) - 16
            rotation: modelData.edge === "left" ? -90 : modelData.edge === "right" ? 90 : 0
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: "\u{F10A9}  " + modelData.label
            color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 0.95 : 0.6)
            font.family: Commons.Style.font.family
            font.pixelSize: 13
            font.bold: true
          }
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: snapBar
      required property var modelData
      readonly property var mon: root.dragData ? root.dragData.monitors.find(m => m.name === modelData.name) || null : null
      screen: modelData
      visible: mon !== null && !root.dragWide
      anchors.top: true
      margins.top: mon ? mon.area[1] - mon.y + root.barGap : 0
      implicitWidth: root.barWidth
      implicitHeight: mon ? root.barHeight(mon) : 1
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      mask: Region {}  // the pointer goes through: the drag carries on underneath
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "omext-zones-bar"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        anchors.fill: parent
        radius: 10
        color: Commons.Util.alpha(Commons.Color.popups.background, 0.92)
        border.color: Commons.Util.alpha(root.accent, 0.6)

        Repeater {
          model: snapBar.mon ? snapBar.mon.zones : []
          Rectangle {
            required property var modelData
            required property int index
            readonly property var r: root.miniZone(snapBar.mon, modelData)
            // Filling lights them all: the window gets the lot.
            readonly property bool lit: snapBar.mon !== null && root.hasZone(root.hover, snapBar.mon.name, index)
            x: r[0] + 2; y: r[1] + 2
            width: r[2] - 4; height: r[3] - 4
            radius: 5
            color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
            border.width: lit ? 2 : 1
            border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
            Text {
              anchors.centerIn: parent
              text: index + 1
              color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.6)
              font.family: Commons.Style.font.family
              font.pixelSize: Math.min(parent.height, parent.width) / 3
              font.bold: true
            }
          }
        }

        // Fill the screen.
        Rectangle {
          readonly property var r: snapBar.mon ? root.fillStrip(snapBar.mon) : [0, 0, 0, 0]
          readonly property bool lit: root.hover !== null && snapBar.mon !== null
                                      && root.hover.monitor === snapBar.mon.name && root.hover.zone === -1
          x: r[0] + 2; y: r[1]
          width: r[2] - 4; height: r[3]
          radius: 5
          color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
          border.width: lit ? 2 : 1
          border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
          Text {
            anchors.centerIn: parent
            text: "\u{F0293}  Fill screen"
            color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
            font.family: Commons.Style.font.family
            font.pixelSize: 11
          }
        }

        // Into one of the screen's docks (omext docks), on its side of the map.
        Repeater {
          model: snapBar.mon ? root.docksFor(snapBar.mon) : []
          Rectangle {
            id: dockStripItem
            required property var modelData
            required property int index
            readonly property var r: root.dockStrip(snapBar.mon, modelData)
            readonly property bool upright: modelData.edge === "left" || modelData.edge === "right"
            readonly property bool lit: root.hover !== null && root.hover.dock === modelData.id
            x: r[0] + 2; y: r[1]
            width: r[2] - 4; height: r[3]
            radius: 5
            color: lit ? Commons.Util.alpha(root.accent, 0.6) : Commons.Util.alpha(Commons.Color.foreground, 0.12)
            border.width: lit ? 2 : 1
            border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.4)
            Text {  // along the strip: read upwards on the left, downwards on the right
              anchors.centerIn: parent
              width: (dockStripItem.upright ? parent.height : parent.width) - 8
              rotation: modelData.edge === "left" ? -90 : modelData.edge === "right" ? 90 : 0
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: "\u{F10A9}  " + modelData.label
              color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.7)
              font.family: Commons.Style.font.family
              font.pixelSize: 11
            }
          }
        }
      }
    }
  }

  Process {
    id: listProc
    command: [root.tool, "list"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.load(text) }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.placeOn(text) }
  }

  Process {
    id: saveProc
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: code => {
      if (code !== 0) { root.editError = saveErr.text.replace(/^omext-zone: /, "").trim(); return }
      root.stopEditing()
      listProc.running = false
      listProc.running = true
    }
  }

  Process {
    id: useProc
    onExited: { listProc.running = false; listProc.running = true }
  }

  PanelWindow {
    id: overlay
    visible: root.open
    screen: root.screenFor(root.monitor)
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: Commons.Util.alpha(Commons.Color.background, 0.35)
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omext-zones"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Item {
      id: focusTaker
      anchors.fill: parent
      focus: true
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Shift) root.shiftDown = true
        if (root.editing) {
          if (event.key === Qt.Key_Escape) root.stopEditing()
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.save()
        }
        else if (event.key === Qt.Key_Escape) root.close()
        else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) root.snap([event.key - Qt.Key_1].filter(i => root.monitor && i < root.monitor.zones.length))
        event.accepted = true
      }
      Keys.onReleased: event => { if (event.key === Qt.Key_Shift) root.shiftDown = false }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: root.editing && (root.line || root.dividerAt(root.pointer.x, root.pointer.y))
                     ? ((root.line || root.dividerAt(root.pointer.x, root.pointer.y)).vertical ? Qt.SplitHCursor : Qt.SplitVCursor)
                     : Qt.ArrowCursor
        onPositionChanged: mouse => {
          root.pointer = Qt.point(mouse.x, mouse.y)
          if (root.editing) {
            root.shiftDown = (mouse.modifiers & Qt.ShiftModifier) !== 0
            if (pressed && root.line) root.moveDivider(mouse.x, mouse.y)
            else if (pressed) {
              var j = root.draftAt(mouse.x, mouse.y)
              if (j >= 0 && root.picked.indexOf(j) < 0) root.picked = root.picked.concat([j])
            }
            return
          }
          root.hovered = root.zoneAt(mouse.x, mouse.y)
          if (pressed && root.hovered >= 0 && root.picked.indexOf(root.hovered) < 0)
            root.picked = root.picked.concat([root.hovered])
        }
        onPressed: mouse => {
          if (root.editing) {
            if (mouse.button === Qt.RightButton) return
            root.editError = ""
            root.line = root.dividerAt(mouse.x, mouse.y)
            var k = root.draftAt(mouse.x, mouse.y)
            root.picked = root.line || k < 0 ? [] : [k]
            return
          }
          if (mouse.button === Qt.RightButton) { root.close(); return }
          var i = root.zoneAt(mouse.x, mouse.y)
          root.picked = i >= 0 ? [i] : []
        }
        onReleased: mouse => {
          if (mouse.button !== Qt.LeftButton) return
          if (!root.editing) { root.snap(root.picked); return }
          if (root.line) root.line = null
          else if (root.picked.length === 1) root.split(mouse.x, mouse.y, (mouse.modifiers & Qt.ShiftModifier) !== 0)
          else if (root.picked.length > 1) root.join(root.picked)
          root.picked = []
        }
      }

      // The zones, where they are on the screen. Spanning lights up the whole
      // stretch the window will get.
      Repeater {
        model: root.monitor && !root.editing ? root.monitor.zones : []
        Rectangle {
          required property var modelData
          required property int index
          readonly property bool lit: root.picked.indexOf(index) >= 0 || (root.picked.length === 0 && root.hovered === index)
          x: modelData[0] - root.monitor.x
          y: modelData[1] - root.monitor.y
          width: modelData[2]
          height: modelData[3]
          radius: 10
          color: lit ? Commons.Util.alpha(root.accent, 0.35) : Commons.Util.alpha(Commons.Color.background, 0.55)
          border.width: 2
          border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.5)
          Text {
            anchors.centerIn: parent
            text: index + 1
            color: Commons.Util.alpha(Commons.Color.foreground, parent.lit ? 1 : 0.6)
            font.family: Commons.Style.font.family
            font.pixelSize: Math.min(parent.height, parent.width) / 5
            font.bold: true
          }
        }
      }

      // Zone sets for this screen, each as a small picture of its zones: your
      // own on top, the built-in ones smaller in a row below.
      Rectangle {
        visible: !root.editing
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.monitor ? root.monitor.area[1] - root.monitor.y + 16 : 16
        width: setColumn.implicitWidth + 16
        height: setColumn.implicitHeight + 16
        radius: 8
        color: Commons.Color.popups.background
        border.color: Commons.Util.alpha(Commons.Color.popups.border, 0.6)
        // Clicks here are for the sets, not the zones underneath.
        MouseArea { anchors.fill: parent; hoverEnabled: true; onPositionChanged: root.hovered = -1 }

        Column {
          id: setColumn
          anchors.centerIn: parent
          spacing: 8
          // Your own sets on the left, the buttons on the right, as tall as a set.
          Item {
            id: topRow
            width: Math.max(ownRow.implicitWidth + 16 + buttons.width, builtInRow.visible ? builtInRow.implicitWidth : 0)
            height: 72
            Row {
              id: ownRow
              spacing: 8
              Repeater {
                model: root.rowSets(true)
                SetTile { required property string modelData; name: modelData }
              }
            }
            Column {
              id: buttons
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: 3
              Btn {
                small: true
                visible: !root.choosing
                label: root.monitor && root.isCustom(root.monitor.set) ? "Edit" : "Edit a copy"
                onClicked: root.edit(false)
              }
              Btn { small: true; visible: !root.choosing; label: "New"; onClicked: root.edit(true) }
              Btn { small: true; label: root.choosing ? "Done" : "Choose"; onClicked: root.choosing = !root.choosing }
            }
          }
          Rectangle {
            visible: builtInRow.visible
            width: topRow.width
            height: 1
            color: Commons.Util.alpha(Commons.Color.popups.border, 0.4)
          }
          Row {
            id: builtInRow
            visible: root.rowSets(false).length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 4
            Repeater {
              model: root.rowSets(false)
              SetTile { required property string modelData; name: modelData; small: true }
            }
          }
        }
      }

      // Editor: the set being made, full size.
      Repeater {
        model: root.editing ? root.draft : []
        Rectangle {
          required property var modelData
          required property int index
          readonly property var a: root.areaBox()
          readonly property bool lit: root.picked.length > 1 && root.picked.indexOf(index) >= 0
          x: a[0] + modelData[0] * a[2] + 3
          y: a[1] + modelData[1] * a[3] + 3
          width: modelData[2] * a[2] - 6
          height: modelData[3] * a[3] - 6
          radius: 8
          color: lit ? Commons.Util.alpha(root.accent, 0.35) : Commons.Util.alpha(Commons.Color.background, 0.6)
          border.width: 2
          border.color: Commons.Util.alpha(root.accent, lit ? 1 : 0.6)
          Text {
            anchors.centerIn: parent
            text: index + 1
            color: Commons.Util.alpha(Commons.Color.foreground, 0.6)
            font.family: Commons.Style.font.family
            font.pixelSize: Math.min(parent.height, parent.width) / 6
            font.bold: true
          }
        }
      }

      // Where a click would split the zone under the pointer.
      Rectangle {
        readonly property var cut: root.editing && !root.line && root.picked.length < 2 && !root.dividerAt(root.pointer.x, root.pointer.y)
                                 ? root.splitAt(root.pointer.x, root.pointer.y, root.shiftDown) : null
        readonly property var box: cut ? root.draft[cut[0]] : null
        readonly property var a: root.editing ? root.areaBox() : [0, 0, 0, 0]
        visible: cut !== null
        color: root.accent
        x: !cut ? 0 : cut[1] ? a[0] + cut[2] * a[2] - 1 : a[0] + box[0] * a[2] + 3
        y: !cut ? 0 : cut[1] ? a[1] + box[1] * a[3] + 3 : a[1] + cut[2] * a[3] - 1
        width: !cut ? 0 : cut[1] ? 2 : box[2] * a[2] - 6
        height: !cut ? 0 : cut[1] ? box[3] * a[3] - 6 : 2
      }

      // Name, save, and the how-to.
      Rectangle {
        visible: root.editing
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.monitor ? root.monitor.area[1] - root.monitor.y + root.monitor.area[3] - height - 16 : 0
        width: editColumn.implicitWidth + 24
        height: editColumn.implicitHeight + 20
        radius: 8
        color: Commons.Color.popups.background
        border.color: Commons.Util.alpha(Commons.Color.popups.border, 0.6)
        MouseArea { anchors.fill: parent; hoverEnabled: true; onPositionChanged: root.pointer = Qt.point(-1, -1) }

        Column {
          id: editColumn
          anchors.centerIn: parent
          spacing: 8
          Text {
            text: "Click a zone to split it (Shift: across) · drag a divider to resize · drag over zones to join them"
            color: Commons.Util.alpha(Commons.Color.popups.text, 0.7)
            font.family: Commons.Style.font.family
            font.pixelSize: 12
          }
          Row {
            spacing: 8
            anchors.horizontalCenter: parent.horizontalCenter
            Rectangle {
              width: 220
              height: 30
              radius: 6
              color: Commons.Util.alpha(Commons.Color.foreground, 0.08)
              border.color: Commons.Util.alpha(root.accent, nameInput.activeFocus ? 1 : 0.4)
              TextInput {
                id: nameInput
                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                verticalAlignment: TextInput.AlignVCenter
                color: Commons.Color.popups.text
                font.family: Commons.Style.font.family
                font.pixelSize: 13
                maximumLength: 24
                clip: true
                Keys.onReturnPressed: root.save()
                Keys.onEscapePressed: root.stopEditing()
                Text {
                  visible: !parent.text
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Name"
                  color: Commons.Util.alpha(Commons.Color.popups.text, 0.4)
                  font: parent.font
                }
              }
            }
            Btn { label: "Save"; onClicked: root.save() }
            Btn { label: "Cancel"; onClicked: root.stopEditing() }
            Btn { label: "Delete"; visible: root.original !== ""; onClicked: root.remove() }
          }
          Text {
            visible: root.editError !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.editError
            color: Commons.Color.accent
            font.family: Commons.Style.font.family
            font.pixelSize: 12
          }
        }
      }
    }
  }
}
