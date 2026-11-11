import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Arrange (omext arrange, from omarchy-extended): the bar widget for saved
// window layouts, and for each screen's zones.
// The pill shows the current layout's icon and a reset button; the popout
// lists layouts with a preview of every screen (a click, or its number key,
// applies one), and can save the current windows as a new layout, update one,
// or remove one. Beside them, each screen with its zones: a click on a zone puts
// the active window there, a click on a set gives the screen that set, Edit and
// New open the zone editor there, and Choose sets picks the sets offered.
// omext-layout and omext-zone do the work; this file only renders their JSON.
Panel {
  id: root
  moduleName: "omext.arrange"
  ipcTarget: "omext.arrange"

  readonly property string tool: Quickshell.env("HOME") + "/.local/bin/omext-layout"
  readonly property string zoneTool: Quickshell.env("HOME") + "/.local/bin/omext-zone"
  property var zoneScreens: []  // omext-zone list's screens, left to right
  property var zoneSets: ({})   // every set: name -> zones (fractions of the free area)
  property var zoneHidden: []   // sets left out of the picker's row (left out here too)
  property var zoneCustom: []   // sets of your own (made in the picker's editor): shown first
  readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omext/layouts/current"
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string defaultIcon: String.fromCodePoint(0xF056E)
  readonly property var iconChoices: [0xF056E, 0xF0379, 0xF0322, 0xF00D6, 0xF018D, 0xF0169, 0xF06A9, 0xF01EE, 0xF02DC, 0xF0306]
    .map(function(c) { return String.fromCodePoint(c) })

  property var layouts: []
  property string currentId: ""
  property int cursor: 0
  property bool busy: false
  property string error: ""
  // "list", "save" (new layout form), or "confirm" (update/remove prompt)
  property string mode: "list"
  property string confirmAction: ""
  property var confirmLayout: null
  property string newIcon: defaultIcon

  readonly property var current: {
    for (var i = 0; i < layouts.length; i++) if (layouts[i].id === currentId) return layouts[i]
    return null
  }

  function refresh() {
    listProc.running = false
    listProc.running = true
    zonesProc.running = false
    zonesProc.running = true
  }

  // The zone editor on that screen: "copy" its set (yours: that one), "new" a blank one.
  function editZones(screen, how) {
    root.close()
    Quickshell.execDetached([root.zoneTool, "pick", "--screen", screen.name, "--edit", how])
  }
  // The sets a screen offers here: those in the picker's row, and the one it
  // has; your own first, then the built-in ones.
  // Choosing which sets every screen offers (as the picker's Choose does).
  property bool choosingSets: false
  function toggleSet(name) {
    zoneProc.closeAfter = false
    zoneProc.command = [root.zoneTool, zoneHidden.indexOf(name) >= 0 ? "show" : "hide", name]
    zoneProc.running = true
  }
  function screenLabel(screen) { return (screen.description || screen.name || "").split(/\s+/)[0] }
  function setsFor(screen) {
    var own = [], builtIn = []
    for (var n in zoneSets)
      if (choosingSets || n === screen.set || zoneHidden.indexOf(n) < 0)
        (zoneCustom.indexOf(n) >= 0 ? own : builtIn).push(n)
    return own.concat(builtIn)
  }
  function useSet(screen, name) {
    if (name === screen.set) return
    zoneProc.closeAfter = false
    zoneProc.command = [root.zoneTool, "use", name, "--monitor", screen.name]
    zoneProc.running = true
  }
  // The active window into a zone (1-based) of that screen.
  function snapTo(screen, n) {
    zoneProc.closeAfter = true
    zoneProc.command = [root.zoneTool, "snap", String(n), "--monitor", screen.name]
    zoneProc.running = true
  }

  function run(args, closeAfter) {
    if (busy) return
    busy = true
    error = ""
    actionProc.closeAfter = closeAfter === true
    actionProc.command = [root.tool].concat(args)
    actionProc.running = true
  }

  function applyLayout(layout) { run(["apply", layout.id], true) }
  function reset() { if (currentId !== "") run(["reset"], false) }

  function askConfirm(action, layout) {
    confirmAction = action
    confirmLayout = layout
    mode = "confirm"
  }

  function confirm() {
    if (!confirmLayout) return
    if (confirmAction === "remove") run(["remove", confirmLayout.id], false)
    else run(["save", confirmLayout.name, "--id", confirmLayout.id], false)
    mode = "list"
  }

  function startSave() {
    newIcon = defaultIcon
    nameField.text = ""
    mode = "save"
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function save() {
    var name = nameField.text.trim()
    if (name === "") return
    run(["save", name, "--icon", newIcon], false)
    mode = "list"
    keyCatcher.forceActiveFocus()
  }

  function cancel() {
    mode = "list"
    keyCatcher.forceActiveFocus()
  }

  // Breathing room on the left so the pill reads as its own group in the bar.
  readonly property real sidePadding: Style.space(root.setting("padding", 16))

  implicitWidth: pill.implicitWidth + sidePadding
  implicitHeight: pill.implicitHeight

  onOpenedChanged: if (opened) {
    mode = "list"
    choosingSets = false
    error = ""
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh()

  Process {
    id: listProc
    command: [root.tool, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.layouts = JSON.parse(text || "[]") } catch (e) { root.layouts = [] }
        var cur = ""
        for (var i = 0; i < root.layouts.length; i++) if (root.layouts[i].current) cur = root.layouts[i].id
        root.currentId = cur
        root.cursor = Math.max(0, Math.min(root.cursor, root.layouts.length - 1))
      }
    }
  }

  Process {
    id: zonesProc
    command: [root.zoneTool, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var got = [], all = {}
        try { all = JSON.parse(text || "{}"); got = all.monitors || [] } catch (e) { got = [] }
        root.zoneSets = all.sets || {}
        root.zoneHidden = all.hidden || []
        root.zoneCustom = all.custom || []
        root.zoneScreens = got.slice().sort(function(a, b) { return a.x - b.x || a.y - b.y })
      }
    }
    onExited: function(code) { if (code !== 0) root.zoneScreens = [] }
  }

  Process {
    id: zoneProc
    property bool closeAfter: false
    stderr: StdioCollector { id: zoneErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = String(zoneErr.text || "").trim() || "omext-zone failed"
      else if (zoneProc.closeAfter) root.close()
      root.refresh()
    }
  }

  Process {
    id: actionProc
    property bool closeAfter: false
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) root.error = String(actionErr.text || "").trim() || "omext-layout failed"
      else if (actionProc.closeAfter) root.close()
      root.refresh()
    }
  }

  // Layout shortcuts and other callers change the current layout too.
  FileView {
    path: root.stateFile
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  // --- bar pill ------------------------------------------------------------

  Row {
    id: pill
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.leftMargin: root.sidePadding

    WidgetButton {
      id: button
      bar: root.bar
      text: (root.current ? root.current.icon : root.defaultIcon) + "  " + root.setting("label", "Arrange")
      tooltipText: root.current ? "Layout: " + root.current.name : "No layout applied yet"
      onPressed: function(b) {
        if (b === Qt.MiddleButton) root.reset()
        else root.toggle()
      }
    }

    BarIconButton {
      bar: root.bar
      visible: root.currentId !== ""
      text: String.fromCodePoint(0xF0450)
      slotSize: Style.bar.statusSlot
      tooltipText: root.current ? "Reset to " + root.current.name : ""
      dimmed: root.busy
      onPressed: root.reset()
    }
  }

  // --- popout --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Layouts on the left; each screen's zones on the right.
    readonly property bool twoCols: root.zoneScreens.length > 0
    readonly property real gap: Style.space(18)
    readonly property real zonesW: Style.space(460)
    readonly property real layoutsW: Style.space(twoCols ? 540 : 460)
    contentWidth: panel.fittedContentWidth(layoutsW + (twoCols ? zonesW + gap : 0))
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, zoneCol.implicitHeight), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.mode === "list" && root.layouts.length > 0)
          root.cursor = Math.max(0, Math.min(root.layouts.length - 1, root.cursor + dy))
      }
      onActivateRequested: {
        if (root.mode === "confirm") root.confirm()
        else if (root.mode === "list" && root.layouts.length > 0) root.applyLayout(root.layouts[root.cursor])
      }
      onDeleteRequested: if (root.mode === "list" && root.layouts.length > 0) root.askConfirm("remove", root.layouts[root.cursor])
      onCloseRequested: root.mode === "list" ? root.close() : root.cancel()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.mode !== "list") return
        if (t >= "1" && t <= "9" && Number(t) <= root.layouts.length) root.applyLayout(root.layouts[Number(t) - 1])
        else if (t === "n" || t === "N") root.startSave()
        else if ((t === "u" || t === "U") && root.layouts.length > 0) root.askConfirm("update", root.layouts[root.cursor])
        else if (t === "r" || t === "R") root.reset()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(column.implicitHeight, zoneCol.implicitHeight)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Row {
          spacing: panel.twoCols ? panel.gap / 2 : 0  // either side of the line

        Column {
          id: column
          width: panel.twoCols ? Math.max(Style.space(380), flick.width - panel.gap - 1 - panel.zonesW) : flick.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "LAYOUTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.error !== ""
            width: parent.width
            text: root.error
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.layouts.length === 0
            width: parent.width
            text: "No layouts yet. Arrange your windows, then save them here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.layouts
              LayoutRow {
                required property var modelData
                required property int index
                width: column.width
                layout: modelData
                rowIndex: index
              }
            }
          }

          // Inline confirmation for update / remove.
          Rectangle {
            visible: root.mode === "confirm"
            width: parent.width
            implicitHeight: confirmCol.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.06)

            Column {
              id: confirmCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                text: !root.confirmLayout ? "" : root.confirmAction === "remove"
                  ? "Remove “" + root.confirmLayout.name + "”?"
                  : "Replace “" + root.confirmLayout.name + "” with the windows on screen now?"
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: root.confirmAction === "remove" ? "Remove" : "Update"
                  onClicked: root.confirm()
                }
                Button {
                  text: "Cancel"
                  onClicked: root.cancel()
                }
              }
            }
          }

          // New layout form.
          Rectangle {
            visible: root.mode === "save"
            width: parent.width
            implicitHeight: saveCol.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.06)

            Column {
              id: saveCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: "Save the windows on screen now as a new layout"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextField {
                id: nameField
                width: parent.width
                placeholderText: "Name"
                foreground: root.foreground
                onAccepted: root.save()
                Keys.onEscapePressed: root.cancel()
              }

              Flow {
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: root.iconChoices
                  Rectangle {
                    required property string modelData
                    width: Style.space(28)
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    color: modelData === root.newIcon ? Util.alpha(root.foreground, 0.18) : (iconMouse.containsMouse ? Util.alpha(root.foreground, 0.08) : "transparent")
                    Text {
                      anchors.centerIn: parent
                      text: parent.modelData
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge
                    }
                    MouseArea {
                      id: iconMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.newIcon = parent.modelData
                    }
                  }
                }
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: "Save"
                  enabled: nameField.text.trim() !== ""
                  onClicked: root.save()
                }
                Button {
                  text: "Cancel"
                  onClicked: root.cancel()
                }
              }
            }
          }

          PanelSeparator {
            visible: root.mode === "list"
            foreground: root.foreground
          }

          // Footer: save new layout.
          CursorSurface {
            visible: root.mode === "list"
            width: parent.width
            foreground: root.foreground
            hasCursor: saveMouse.containsMouse
            implicitHeight: saveRow.implicitHeight + Style.spacing.rowPaddingX

            RowLayout {
              id: saveRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)
              Text {
                text: String.fromCodePoint(0xF0415)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
              Text {
                Layout.fillWidth: true
                text: "Save current windows as new layout"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: "n"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: saveMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startSave()
            }
          }

          Text {
            visible: root.mode === "list" && root.layouts.length > 0
            width: parent.width
            text: "1–9 or Enter apply · u update · x remove · r reset · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // Zones: each screen's zones and sets.
        Rectangle {  // between the columns
          visible: panel.twoCols
          width: 1
          height: Math.max(column.implicitHeight, zoneCol.implicitHeight)
          color: Util.alpha(root.foreground, 0.12)
        }

        Column {
          id: zoneCol
          visible: panel.twoCols
          width: panel.twoCols ? flick.width - panel.gap - 1 - column.width : 0
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: zonesHead.implicitHeight
            PanelSectionHeader {
              id: zonesHead
              width: parent.width
              text: "ZONES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            // Which sets the screens offer, for all of them.
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.choosingSets ? "Done" : "Choose sets"
              color: chooseMouse.containsMouse || root.choosingSets ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: chooseMouse.containsMouse
              MouseArea {
                id: chooseMouse
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.choosingSets = !root.choosingSets
              }
            }
          }

          Text {
            visible: root.choosingSets
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Click a set to show or hide it on every screen. Dimmed sets are hidden."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.zoneScreens
              ZoneRow {
                required property var modelData
                width: zoneCol.width
                screen: modelData
              }
            }
          }
        }
        }
      }
    }
  }

  // --- one layout row --------------------------------------------------------

  component LayoutRow: CursorSurface {
    id: row

    property var layout: ({})
    property int rowIndex: 0
    readonly property bool hot: rowMouse.containsMouse || updateMouse.containsMouse || removeMouse.containsMouse

    foreground: root.foreground
    hasCursor: root.mode === "list" && root.cursor === rowIndex
    current: layout.id === root.currentId
    implicitHeight: Style.space(92)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = row.rowIndex
      onClicked: root.applyLayout(row.layout)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(6)
      anchors.bottomMargin: Style.space(6)
      spacing: Style.space(10)

      Text {
        text: row.layout.icon || root.defaultIcon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
        Layout.alignment: Qt.AlignVCenter
      }

      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.spacing.labelGap
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: row.layout.name + (row.current ? "  ✓" : "")
          rightPadding: Style.space(16)
          Text {  // its number key
            visible: row.rowIndex < 9
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: row.rowIndex + 1
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: {
            var screens = row.layout.screens || []
            var n = 0
            for (var i = 0; i < screens.length; i++) n += screens[i].windows.length
            return screens.length + (screens.length === 1 ? " screen · " : " screens · ") + n + (n === 1 ? " window" : " windows")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Row {
          visible: row.hot || row.hasCursor
          spacing: Style.space(4)
          PanelActionButton {
            iconText: String.fromCodePoint(0xF0193)
            tooltipText: "Update with current windows"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onClicked: root.askConfirm("update", row.layout)
            MouseArea { id: updateMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          }
          PanelActionButton {
            iconText: String.fromCodePoint(0xF0A7A)
            tooltipText: "Remove"
            foreground: root.foreground
            hoverColor: root.urgent
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onClicked: root.askConfirm("remove", row.layout)
            MouseArea { id: removeMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          }
        }
      }

      LayoutPreview {
        Layout.preferredWidth: Style.space(220)
        Layout.fillHeight: true
        screens: row.layout.screens || []
      }
    }
  }

  // --- one screen's zones ------------------------------------------------------

  component ZoneRow: CursorSurface {
    id: zrow

    property var screen: ({})

    foreground: root.foreground
    hasCursor: false
    implicitHeight: zcol.implicitHeight + Style.space(20)

    Rectangle {  // a card per screen
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.04)
      border.width: 1
      border.color: Util.alpha(root.foreground, 0.1)
    }

    Column {
      id: zcol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(10)
      spacing: Style.space(8)

      RowLayout {
        id: zhead
        width: parent.width
        height: Style.space(78)
        spacing: Style.space(12)

        // The screen's free area with its zones: a click puts the active window in one.
        Item {
          id: zprev
          Layout.preferredWidth: Style.space(130)
          Layout.fillHeight: true
          readonly property var area: zrow.screen.area || [0, 0, 1, 1]
          readonly property real scale: Math.min(width / area[2], height / area[3])
          readonly property real ox: (width - area[2] * scale) / 2
          readonly property real oy: (height - area[3] * scale) / 2
          QtObject { id: zhover; property int n: 0 }

          Repeater {
            model: zrow.screen.zones || []
            Rectangle {
              required property var modelData
              required property int index
              x: zprev.ox + (modelData[0] - zprev.area[0]) * zprev.scale + 1
              y: zprev.oy + (modelData[1] - zprev.area[1]) * zprev.scale + 1
              width: Math.max(2, modelData[2] * zprev.scale - 2)
              height: Math.max(2, modelData[3] * zprev.scale - 2)
              radius: 2
              color: Util.alpha(root.foreground, zm.containsMouse ? 0.4 : 0.16)
              border.width: 1
              border.color: Util.alpha(root.foreground, zm.containsMouse ? 0.9 : 0.45)
              Text {
                anchors.centerIn: parent
                text: parent.index + 1
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                visible: parent.width > 12 && parent.height > 12
              }
              MouseArea {
                id: zm
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: zhover.n = containsMouse ? parent.index + 1 : (zhover.n === parent.index + 1 ? 0 : zhover.n)
                onClicked: root.snapTo(zrow.screen, parent.index + 1)
              }
            }
          }
        }

        Column {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.spacing.labelGap
          Text {
            width: parent.width
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            text: root.screenLabel(zrow.screen) + (zrow.screen.focused ? "  •" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            text: zhover.n > 0 ? "Put the active window in zone " + zhover.n
                               : (zrow.screen.set || "") + " · click a zone"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          // Straight into the editor: this set (a copy of a built-in one), or a new one.
          Row {
            visible: !root.choosingSets
            anchors.right: parent.right
            topPadding: Style.space(4)
            spacing: Style.space(4)
            Repeater {
              model: [
                { how: "copy", label: root.zoneCustom.indexOf(zrow.screen.set) >= 0 ? "Edit" : "Edit a copy",
                  tip: "Change the zones of " + zrow.screen.set },
                { how: "new", label: "New", tip: "Draw a new set of zones" }]
              Rectangle {
                id: eb
                required property var modelData
                width: Style.space(84)
                height: Style.space(24)
                radius: Style.cornerRadius
                color: ebMouse.containsMouse ? Util.alpha(root.foreground, 0.12) : "transparent"
                border.width: 1
                border.color: Util.alpha(root.foreground, 0.15)
                Text {
                  anchors.centerIn: parent
                  text: eb.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: ebMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.editZones(zrow.screen, eb.modelData.how)
                }
              }
            }
          }
        }
      }

      // Its sets: a click gives the screen that one (choosing: shows or hides
      // it, for every screen).
      Flow {
        id: setFlow
        width: parent.width
        spacing: Style.space(4)
        // Six to a row, sharing the card's width.
        readonly property real chipW: Math.floor((width - 5 * spacing) / 6)
        Repeater {
          model: root.setsFor(zrow.screen)
          Rectangle {
            id: chip
            required property string modelData
            readonly property bool on: modelData === zrow.screen.set
            readonly property bool off: root.zoneHidden.indexOf(modelData) >= 0
            opacity: root.choosingSets && off ? 0.35 : 1
            width: setFlow.chipW
            height: Style.space(54)
            radius: Style.cornerRadius
            color: on ? Util.alpha(root.foreground, 0.16) : (chipMouse.containsMouse ? Util.alpha(root.foreground, 0.08) : "transparent")
            border.width: 1
            border.color: Util.alpha(root.foreground, on ? 0.7 : 0.15)
            Item {
              id: mini
              anchors.horizontalCenter: parent.horizontalCenter
              y: Style.space(4)
              width: parent.width - Style.space(12)
              height: Style.space(30)
              Repeater {
                model: root.zoneSets[chip.modelData] || []
                Rectangle {
                  required property var modelData
                  x: modelData[0] * mini.width + 0.5
                  y: modelData[1] * mini.height + 0.5
                  width: Math.max(1, modelData[2] * mini.width - 1)
                  height: Math.max(1, modelData[3] * mini.height - 1)
                  radius: 1
                  color: Util.alpha(root.foreground, chip.on ? 0.35 : 0.18)
                }
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(3)
              width: parent.width - Style.space(4)
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: chip.modelData
              color: chip.on ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {  // shown or hidden, while choosing
              visible: root.choosingSets
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 2
              text: chip.off ? String.fromCodePoint(0xF0209) : String.fromCodePoint(0xF0208)
              color: chip.off ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: chipMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.choosingSets ? root.toggleSet(chip.modelData) : root.useSet(zrow.screen, chip.modelData)
            }
          }
        }
      }
    }
  }

  // --- preview: every screen in its real arrangement, windows as boxes -------

  component LayoutPreview: Item {
    id: preview

    property var screens: []

    readonly property var bounds: {
      var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
      for (var i = 0; i < screens.length; i++) {
        var s = screens[i]
        x0 = Math.min(x0, s.x); y0 = Math.min(y0, s.y)
        x1 = Math.max(x1, s.x + s.width); y1 = Math.max(y1, s.y + s.height)
      }
      return screens.length ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 1, h: 1 }
    }
    readonly property real scale: Math.min(width / bounds.w, height / bounds.h)
    readonly property real offsetX: (width - bounds.w * scale) / 2
    readonly property real offsetY: (height - bounds.h * scale) / 2

    Repeater {
      model: preview.screens
      Rectangle {
        id: screen
        required property var modelData
        x: preview.offsetX + (modelData.x - preview.bounds.x) * preview.scale
        y: preview.offsetY + (modelData.y - preview.bounds.y) * preview.scale
        width: modelData.width * preview.scale
        height: modelData.height * preview.scale
        radius: 2
        color: "transparent"
        border.width: 1
        border.color: Util.alpha(root.foreground, 0.35)
        opacity: modelData.connected ? 1 : 0.35

        Repeater {
          model: screen.modelData.windows
          Rectangle {
            required property var modelData
            x: modelData.rect[0] * screen.width + 1
            y: modelData.rect[1] * screen.height + 1
            width: Math.max(2, modelData.rect[2] * screen.width - 2)
            height: Math.max(2, modelData.rect[3] * screen.height - 2)
            radius: 1
            color: Util.alpha(root.foreground, modelData.floating ? 0.30 : 0.16)
            border.width: 1
            border.color: Util.alpha(root.foreground, 0.45)
            clip: true

            Text {
              anchors.fill: parent
              anchors.margins: 1
              visible: parent.width > 18 && parent.height > 8
              text: parent.modelData.label
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Math.max(5, Math.min(7, parent.height - 2))
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }
        }
      }
    }
  }
}
