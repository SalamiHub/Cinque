import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cinque bar widget: bar icon + popup wrapping the quattro-workstation CLI.
// Follows the pattern used by the real, installed
// davedes.mouse-keybind-settings plugin (a Panel as the barWidget entry
// point root, with an embedded BarIconButton and a KeyboardPanel popup) so
// this widget participates in the bar's real popout/panel coordination
// (same-bar single-popout switching, outside-click dismissal, etc.)
// instead of opening an independent floating window.
Panel {
  id: root
  moduleName: "engine.cinque"
  ipcTarget: "engine.cinque"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- View state. "list" (5 squares) -> "detail" (one slot) -> "edit".
  property string view: "list"
  property int selectedSlot: 0
  property string statusNote: ""

  readonly property var currentSlot: root.selectedSlot > 0 ? root.slots[root.selectedSlot - 1] : null

  // ---- Live state read from ~/.config/quattro-workstations. Re-read from
  // disk every time the popup opens (refreshState), never cached across
  // opens, so the squares always reflect what capture-fluid / boot-slot /
  // fluid / a hand-edited JSON file actually left on disk.
  property var configData: ({ fluidSlot: null, bootSlot: null })
  property var slots: [null, null, null, null, null]

  // ---- Edit buffer, populated by startEdit() and only written back on Save.
  property string editName: ""
  property string editMode: "preset"
  property var editCommands: []
  // "" = nothing picked yet, "__custom__" = the free-text row is showing,
  // anything else = the clean command a picked app resolved to (which is
  // also what gets stored -- picker-selected and hand-typed commands are
  // both just strings once they're in editCommands/on disk).
  property string newCmdValue: ""
  property string newCmdText: ""
  property int newCmdWorkspace: 1

  readonly property string customCommandValue: "__custom__"

  // ---- Installed apps, for the add-command picker. Populated from
  // `quattro-workstation list-apps` (desktop-file scan with field codes
  // like %U/%f already stripped -- see that subcommand), refreshed every
  // time the edit view opens so newly installed apps show up without
  // restarting the shell.
  property var installedApps: []
  readonly property var appPickerOptions: {
    var out = [{ value: root.customCommandValue, label: "Custom command…" }]
    for (var i = 0; i < root.installedApps.length; i++) {
      var a = root.installedApps[i]
      out.push({ value: a.command, label: a.name, description: a.command })
    }
    return out
  }

  function refreshApps() {
    if (appsProc.running) return
    appsProc.command = ["quattro-workstation", "list-apps"]
    appsProc.running = true
  }

  readonly property string quattroHome: Quickshell.env("HOME") + "/.config/quattro-workstations"

  function fileViewForSlot(n) {
    if (n === 1) return ws1File
    if (n === 2) return ws2File
    if (n === 3) return ws3File
    if (n === 4) return ws4File
    if (n === 5) return ws5File
    return null
  }

  function setSlotData(n, raw) {
    var arr = root.slots.slice()
    if (raw === null) {
      arr[n - 1] = null
    } else {
      try { arr[n - 1] = JSON.parse(raw) } catch (e) { arr[n - 1] = null }
    }
    root.slots = arr
  }

  function refreshState() {
    cfgFile.reload()
    ws1File.reload()
    ws2File.reload()
    ws3File.reload()
    ws4File.reload()
    ws5File.reload()
  }

  function slotDisplayName(n) {
    var s = root.slots[n - 1]
    return (s && s.name) ? s.name : ("Workstation " + n)
  }

  function open() {
    root.view = "list"
    root.selectedSlot = 0
    root.statusNote = ""
    root.refreshState()
    root.controller.show()
  }

  // ---- CLI actions. quattro-workstation --help exposes: list, launch,
  // fluid, capture-fluid, boot-slot, boot -- no "unset" subcommand for
  // either boot-slot or fluid, so unsetting is done by writing config.json
  // directly, in the exact {fluidSlot, bootSlot} shape the CLI itself reads
  // and writes (quattro-workstation:default_config()).
  function runCli(args, note) {
    if (cliProc.running) return
    root.statusNote = ""
    root.pendingNote = note
    cliProc.command = ["quattro-workstation"].concat(args)
    cliProc.running = true
  }
  property string pendingNote: ""

  function launchSlot(n) {
    root.runCli(["launch", String(n)], "Launched")
  }

  function toggleBootSlot(n) {
    if (cliProc.running) return
    if (root.configData.bootSlot === n) {
      root.writeConfig({ fluidSlot: root.configData.fluidSlot, bootSlot: null })
      root.statusNote = "Boot slot unset"
      clearNoteTimer.restart()
    } else {
      root.runCli(["boot-slot", String(n)], "Boot slot set")
    }
  }

  function toggleFluidSlot(n) {
    if (cliProc.running) return
    if (root.configData.fluidSlot === n) {
      root.writeConfig({ fluidSlot: null, bootSlot: root.configData.bootSlot })
      root.statusNote = "Fluid slot unset"
      clearNoteTimer.restart()
    } else {
      root.runCli(["fluid", String(n)], "Fluid slot set")
    }
  }

  function writeConfig(obj) {
    root.configData = obj
    cfgFile.setText(JSON.stringify(obj, null, 2) + "\n")
    Qt.callLater(root.refreshState)
  }

  // ---- Edit view. No CLI subcommand renames a slot or edits its command
  // list, so Save writes workstations/<n>.json directly, preserving the
  // exact {id, name, mode, commands} shape quattro-workstation itself uses
  // (see workstations/1.json) and keeping whatever "mode" the slot already
  // had (editing a preset doesn't make it fluid, or vice versa).
  function startEdit(n) {
    var s = root.slots[n - 1]
    root.editName = (s && s.name) ? s.name : ("Workstation " + n)
    root.editMode = (s && s.mode) ? s.mode : "preset"
    var cmds = (s && s.commands) ? s.commands : []
    var copy = []
    for (var i = 0; i < cmds.length; i++)
      copy.push({ command: cmds[i].command, workspace: cmds[i].workspace })
    root.editCommands = copy
    root.newCmdValue = ""
    root.newCmdText = ""
    root.newCmdWorkspace = 1
    if (appPicker) appPicker.value = ""
    root.view = "edit"
    root.refreshApps()
  }

  // A command in editCommands/on disk is always just a plain string --
  // whether it came from picking an app (newCmdValue holds the app's
  // already-clean command) or from the custom-command text field, storage
  // doesn't distinguish the two, so an existing slot's commands (never
  // picked from the dropdown at all) edit exactly the same way.
  function addEditCommand() {
    var text = (root.newCmdValue === root.customCommandValue ? root.newCmdText : root.newCmdValue)
      .replace(/^\s+|\s+$/g, "")
    if (text.length === 0) return
    var copy = root.editCommands.slice()
    copy.push({ command: text, workspace: root.newCmdWorkspace })
    root.editCommands = copy
    root.newCmdValue = ""
    root.newCmdText = ""
    if (appPicker) appPicker.value = ""
  }

  function removeEditCommand(idx) {
    var copy = root.editCommands.slice()
    copy.splice(idx, 1)
    root.editCommands = copy
  }

  function saveEdit() {
    var fv = root.fileViewForSlot(root.selectedSlot)
    if (!fv) return
    var name = root.editName.replace(/^\s+|\s+$/g, "")
    var obj = {
      id: root.selectedSlot,
      name: name.length > 0 ? name : ("Workstation " + root.selectedSlot),
      mode: root.editMode,
      commands: root.editCommands
    }
    fv.setText(JSON.stringify(obj, null, 2) + "\n")
    root.statusNote = "Saved"
    clearNoteTimer.restart()
    root.view = "detail"
    Qt.callLater(root.refreshState)
  }

  // ---- State files. Read directly rather than parsing `list`'s text
  // output, so detail/edit views have the full JSON (commands, mode) that
  // the CLI's own plain-text listing doesn't carry.
  FileView {
    id: cfgFile
    path: root.quattroHome + "/config.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        root.configData = { fluidSlot: (d.fluidSlot || null), bootSlot: (d.bootSlot || null) }
      } catch (e) {
        root.configData = { fluidSlot: null, bootSlot: null }
      }
    }
    onLoadFailed: root.configData = { fluidSlot: null, bootSlot: null }
  }

  FileView {
    id: ws1File
    path: root.quattroHome + "/workstations/1.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.setSlotData(1, text())
    onLoadFailed: root.setSlotData(1, null)
  }
  FileView {
    id: ws2File
    path: root.quattroHome + "/workstations/2.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.setSlotData(2, text())
    onLoadFailed: root.setSlotData(2, null)
  }
  FileView {
    id: ws3File
    path: root.quattroHome + "/workstations/3.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.setSlotData(3, text())
    onLoadFailed: root.setSlotData(3, null)
  }
  FileView {
    id: ws4File
    path: root.quattroHome + "/workstations/4.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.setSlotData(4, text())
    onLoadFailed: root.setSlotData(4, null)
  }
  FileView {
    id: ws5File
    path: root.quattroHome + "/workstations/5.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.setSlotData(5, text())
    onLoadFailed: root.setSlotData(5, null)
  }

  BoundedProcess {
    id: cliProc
    timeoutMs: 8000
    onFinished: {
      root.statusNote = success ? root.pendingNote : "Error"
      root.pendingNote = ""
      root.refreshState()
      clearNoteTimer.restart()
    }
  }

  BoundedProcess {
    id: appsProc
    timeoutMs: 8000
    onFinished: {
      if (!success) return
      try {
        var parsed = JSON.parse(stdout)
        if (Array.isArray(parsed)) root.installedApps = parsed
      } catch (e) {
        // leave the previous list in place on a parse failure
      }
    }
  }

  Timer {
    id: clearNoteTimer
    interval: 2500
    onTriggered: root.statusNote = ""
  }

  // ---- Bar icon: two overlapping squares in the bar's foreground color.
  Component {
    id: cinqueIconComponent
    Item {
      anchors.fill: parent
      readonly property real sq: Math.max(6, Math.round(Math.min(width, height) * 0.6))
      readonly property real off: sq * 0.3

      Rectangle {
        width: parent.sq
        height: parent.sq
        radius: 2
        color: "transparent"
        border.width: Math.max(1, Style.spacing.hairline)
        border.color: root.foreground
        x: parent.width / 2 - width / 2 - parent.off
        y: parent.height / 2 - height / 2 - parent.off
      }
      Rectangle {
        width: parent.sq
        height: parent.sq
        radius: 2
        color: "transparent"
        border.width: Math.max(1, Style.spacing.hairline)
        border.color: root.foreground
        x: parent.width / 2 - width / 2 + parent.off
        y: parent.height / 2 - height / 2 + parent.off
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: cinqueIconComponent
    tooltipText: "Cinque"
    active: root.opened
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: root.view === "edit" ? editNameField : null
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(Style.space(root.view === "edit" ? 460 : (root.view === "list" ? 460 : 400)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.view === "edit"
      onCloseRequested: root.close()

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- Header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "󰆝"
            visible: false // reserved; the bar icon carries the mark, header stays text-only
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
              text: "Cinque"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.view === "list" ? "5 workstation slots"
                : root.view === "edit" ? "Editing slot " + root.selectedSlot
                : "Slot " + root.selectedSlot
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          PanelActionButton {
            iconText: "✕"
            tooltipText: "Close"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.close()
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ---- Content area: exactly one of the three views is visible.
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ===================== LIST VIEW =====================
          ColumnLayout {
            anchors.fill: parent
            visible: root.view === "list"
            spacing: Style.space(12)

            GridLayout {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignHCenter
              columns: 5
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              Repeater {
                model: 5

                delegate: BorderSurface {
                  id: squareDelegate
                  required property int index
                  readonly property int n: index + 1
                  Layout.preferredWidth: Style.space(62)
                  Layout.preferredHeight: Style.space(62)
                  radius: Style.cornerRadius
                  color: sqMouse.containsMouse
                    ? Style.hoverFillFor(root.foreground, root.accentColor)
                    : Style.normalFillFor(root.foreground, root.accentColor)
                  borderSpec: Border.controlSpec(sqMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accentColor)

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 1

                    Text {
                      text: String(squareDelegate.n)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                      Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.slotDisplayName(squareDelegate.n)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1
                      elide: Text.ElideRight
                      Layout.preferredWidth: Style.space(54)
                      horizontalAlignment: Text.AlignHCenter
                    }
                    RowLayout {
                      Layout.alignment: Qt.AlignHCenter
                      spacing: 3
                      Text {
                        visible: root.configData.bootSlot === squareDelegate.n
                        text: "B"
                        color: root.accentColor
                        font.family: root.fontFamily
                        font.bold: true
                        font.pixelSize: Style.font.caption - 1
                      }
                      Text {
                        visible: root.configData.fluidSlot === squareDelegate.n
                        text: "F"
                        color: root.urgentColor
                        font.family: root.fontFamily
                        font.bold: true
                        font.pixelSize: Style.font.caption - 1
                      }
                    }
                  }

                  MouseArea {
                    id: sqMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectedSlot = squareDelegate.n
                      root.view = "detail"
                    }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "B = boot slot   F = fluid slot"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption - 1
              Layout.alignment: Qt.AlignHCenter
            }

            // Quick explainer for the boot/fluid distinction -- secondary to
            // the grid above it (same muted/small styling as the legend
            // line), so it reads as a footnote, not a headline.
            ColumnLayout {
              Layout.fillWidth: true
              Layout.topMargin: Style.space(2)
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: "Boot — always launches this slot on startup, until you change it."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
              Text {
                textFormat: Text.PlainText
                text: "Fluid — saves whatever's open right now, restored next time."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
              Text {
                textFormat: Text.PlainText
                text: "Boot wins — if a slot is both, it still launches every time — fluid just keeps it fresh."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }

            Item { Layout.fillHeight: true }
          }

          // ===================== DETAIL VIEW =====================
          ColumnLayout {
            anchors.fill: parent
            visible: root.view === "detail"
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Back"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.view = "list"
              }
              Text {
                textFormat: Text.PlainText
                text: root.slotDisplayName(root.selectedSlot)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
              Text {
                text: root.currentSlot ? root.currentSlot.mode : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelSeparator { Layout.fillWidth: true }

            Text {
              text: "Commands"
              color: root.accentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            ScrollView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              ColumnLayout {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: (root.currentSlot && root.currentSlot.commands) ? root.currentSlot.commands : []
                  delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.command
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: "ws " + modelData.workspace
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  visible: !root.currentSlot || !root.currentSlot.commands || root.currentSlot.commands.length === 0
                  text: "No commands"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            PanelSeparator { Layout.fillWidth: true }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Launch"
                bordered: true
                onClicked: root.launchSlot(root.selectedSlot)
              }
              Button {
                text: root.configData.bootSlot === root.selectedSlot ? "Unset boot" : "Set boot"
                bordered: true
                selected: root.configData.bootSlot === root.selectedSlot
                onClicked: root.toggleBootSlot(root.selectedSlot)
              }
              Button {
                text: root.configData.fluidSlot === root.selectedSlot ? "Unset fluid" : "Set fluid"
                bordered: true
                selected: root.configData.fluidSlot === root.selectedSlot
                onClicked: root.toggleFluidSlot(root.selectedSlot)
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Edit"
                bordered: true
                onClicked: root.startEdit(root.selectedSlot)
              }
              Item { Layout.fillWidth: true }
              Text {
                text: root.statusNote
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ===================== EDIT VIEW =====================
          ColumnLayout {
            anchors.fill: parent
            visible: root.view === "edit"
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Back"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.view = "detail"
              }
              Text {
                text: "Edit slot " + root.selectedSlot
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                Layout.fillWidth: true
              }
            }

            TextField {
              id: editNameField
              Layout.fillWidth: true
              placeholderText: "Slot name"
              text: root.editName
              foreground: root.foreground
              accent: root.accentColor
              onTextChanged: root.editName = text
            }

            PanelSeparator { Layout.fillWidth: true }

            Text {
              text: "Commands"
              color: root.accentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            ScrollView {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(150)
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              ColumnLayout {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.editCommands
                  delegate: RowLayout {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.command
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: "ws " + modelData.workspace
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      text: "✕"
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      bordered: true
                      onClicked: root.removeEditCommand(index)
                    }
                  }
                }

                Text {
                  visible: root.editCommands.length === 0
                  text: "No commands yet"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              SearchableDropdown {
                id: appPicker
                Layout.fillWidth: true
                showLabel: false
                placeholderText: "Choose an app…"
                emptyText: root.installedApps.length === 0 ? "Loading…" : "No matches"
                options: root.appPickerOptions
                foreground: root.foreground
                accent: root.accentColor
                onChanged: function(v) { root.newCmdValue = v }
              }

              TextField {
                id: newCmdField
                visible: root.newCmdValue === root.customCommandValue
                Layout.fillWidth: true
                placeholderText: "command"
                text: root.newCmdText
                foreground: root.foreground
                accent: root.accentColor
                onTextChanged: root.newCmdText = text
                Keys.onReturnPressed: root.addEditCommand()
              }

              Text {
                textFormat: Text.PlainText
                visible: root.newCmdValue.length > 0 && root.newCmdValue !== root.customCommandValue
                text: "→ " + root.newCmdValue
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.fillWidth: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Item { Layout.fillWidth: true }
                NumberField {
                  label: "Workspace"
                  fieldWidth: Style.space(60)
                  foreground: root.foreground
                  accent: root.accentColor
                  value: root.newCmdWorkspace
                  from: 1
                  to: 50
                  onModified: function(v) { root.newCmdWorkspace = v }
                }
                Button {
                  text: "Add"
                  bordered: true
                  onClicked: root.addEditCommand()
                }
              }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Cancel"
                bordered: true
                onClicked: root.view = "detail"
              }
              Item { Layout.fillWidth: true }
              Button {
                text: "Save"
                bordered: true
                onClicked: root.saveEdit()
              }
            }
          }
        }
      }
    }
  }
}
