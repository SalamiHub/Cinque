# Cinque

A bar widget and CLI for Omarchy/Hyprland that manages 5 "workstation" slots
— saved sets of apps + workspace placements you can launch on demand, plus
one designated **boot slot** (always launches at startup) and one **fluid
slot** (snapshots whatever's open and restores it next boot).

![Cinque bar icon and popup](screenshot.png)
*(screenshot placeholder — replace with an actual capture of the bar icon and
the 5-slot popup)*

## Install

```
git clone <url> && cd cinque && ./install.sh
```

That's it. No manual config, no separate `omarchy plugin add` step. Open the
bar (a small two-overlapping-squares icon appears on the left section) and
start adding apps to a slot from there.

## What `install.sh` does

Every step is idempotent — re-running it never duplicates anything or
overwrites state you've already set up:

1. **Checks dependencies**: `python3`, `hyprctl`, `omarchy`, `jq`. Stops with
   a clear error if any are missing, rather than failing halfway through.
2. **Symlinks** `bin/quattro-workstation` to `~/.local/bin/quattro-workstation`.
3. **Creates** `~/.config/quattro-workstations/` (5 empty slots, no boot/fluid
   slot set) — only for files that don't already exist, so a re-run (or an
   existing setup) is left alone.
4. **Copies** (not symlinks — Omarchy's plugin validator rejects symlinks
   inside a plugin folder) `manifest.json`, `Widget.qml`, and
   `BoundedProcess.qml` into `~/.config/omarchy/plugins/engine.cinque/`,
   validates them (`omarchy plugin validate`), then enables the plugin
   (`omarchy plugin enable engine.cinque left`) — `omarchy plugin add` only
   ever git-clones, so `enable` is the correct call for a plugin already
   placed on disk.
5. **Backs up** `~/.config/hypr/autostart.lua` once, the first time it's
   ever touched (`autostart.lua.bak.<timestamp>` — a second install run
   won't overwrite that original with its own prior edits), then adds the
   two Hyprland boot/shutdown hook lines if they aren't already there.
6. **Restarts the Omarchy shell** (`omarchy restart shell`) so the plugin is
   live immediately — confirmed by checking the `quickshell` process got a
   new PID, not just that the reload command exited 0.
7. Prints a summary of what changed.

## Uninstall

Reverses the above:

```bash
# Remove the plugin
omarchy plugin disable engine.cinque
rm -rf ~/.config/omarchy/plugins/engine.cinque

# Remove the CLI
rm ~/.local/bin/quattro-workstation

# Restore autostart.lua to how it was before Cinque touched it
cp ~/.config/hypr/autostart.lua.bak.<timestamp> ~/.config/hypr/autostart.lua
rm ~/.config/hypr/autostart.lua.bak.<timestamp>
omarchy restart shell

# Optional: drop all slot data
rm -rf ~/.config/quattro-workstations
```

(`ls ~/.config/hypr/autostart.lua.bak.*` to find the exact backup filename —
there's only ever one, from the first install.)

---

## Reference

### Storage

```
~/.config/quattro-workstations/config.json
~/.config/quattro-workstations/workstations/1.json
~/.config/quattro-workstations/workstations/2.json
... 3.json, 4.json, 5.json
```

#### `config.json`

```json
{ "fluidSlot": 3, "bootSlot": 1 }
```

- `fluidSlot` — `null` when no slot is fluid, or an integer 1-5 naming the
  slot that `capture-fluid` writes to and that `boot` falls back to launching.
- `bootSlot` — `null`, or an integer 1-5 naming the preset that should always
  launch at Hyprland startup, independent of whatever the fluid slot is doing.
  This is the one you want set for an "always open this at boot" workstation
  like a coding preset — `boot` only ever touches the fluid slot on its own,
  so a plain preset needs `bootSlot` to auto-launch.

#### `workstations/N.json`

```json
{
  "id": 3,
  "name": "Coding",
  "mode": "preset",
  "commands": [
    { "command": "code ~/projects/cinque", "workspace": 1 },
    { "command": "chromium --new-window", "workspace": 2 }
  ]
}
```

- `id` — matches the filename, 1-5.
- `name` — display name.
- `mode` — `"preset"` (hand-authored/curated) or `"fluid"` (last written by
  `capture-fluid`). Informational only — `launch` treats both the same way.
- `commands` — ordered list. For each entry, `launch` switches Hyprland to
  `workspace`, then runs `command` detached.

### CLI commands

```
quattro-workstation list                # show all 5 slots, name + mode/fluid/boot status
quattro-workstation launch <n>          # switch workspace + run each command in slot n
quattro-workstation fluid <n>           # mark slot n as the fluid slot (unsets any previous one)
quattro-workstation capture-fluid       # snapshot current windows into the fluid slot; no-op if none set
quattro-workstation boot-slot <n>       # mark slot n to always launch at startup, fluid or not
quattro-workstation boot                # launch bootSlot if set, else fluidSlot; no-op if neither set
quattro-workstation list-apps           # JSON [{name, command}] of installed apps, for building commands
```

`list-apps` scans `.desktop` files under `$XDG_DATA_HOME/applications` and
each `$XDG_DATA_DIRS` entry's `applications` dir (in precedence order, so a
same-named file in an earlier dir wins), skips `NoDisplay=true` /
`Hidden=true` entries, and strips `Exec=` field codes (`%f %F %u %U %d %D %n
%N %i %c %k %v %m`) so `command` is directly runnable by `sh -c`. It's what
the bar widget's Edit-view app picker calls.

`launch` runs each command as `setsid nohup sh -c '<command>' </dev/null
>/dev/null 2>&1 &` so it survives the CLI process exiting.

`capture-fluid` reads `hyprctl clients -j`, dedupes windows by `class`, and
writes `<class-lowercased>` as a naive launch command for each — there's no
app resolver yet, so e.g. a captured Chromium window becomes the command
`chromium`, which may not exactly reproduce your session (new window/tab
instead of restored tabs). Good enough for round-tripping "roughly what I had
open."

### Creating a preset slot by hand

Preset slots are just JSON — edit them directly, no CLI command needed:

```bash
$EDITOR ~/.config/quattro-workstations/workstations/1.json
```

Then:

```bash
quattro-workstation launch 1
quattro-workstation boot-slot 1   # optional: also launch it at every startup
```

### Hyprland integration

Omarchy's Hyprland config is Lua-based (`~/.config/hypr/*.lua`), not the
classic `hyprland.conf` text format, and its `hl.on()` event system exposes
`"hyprland.start"` and `"hyprland.shutdown"` as the boot/shutdown hook
points — not the old `exec-once` config keyword. `install.sh` adds these two
lines to `~/.config/hypr/autostart.lua`:

```lua
o.exec_on_start("quattro-workstation boot")
hl.on("hyprland.shutdown", function() hl.exec_cmd("quattro-workstation capture-fluid") end)
```

Also note: `hyprctl dispatch workspace <n>` (the classic syntax) does **not**
work on newer Hyprland builds — the dispatcher is Lua now. `launch` uses
`hyprctl dispatch 'hl.dsp.focus({workspace="<n>"})'` instead.

### Bar widget

`manifest.json` / `Widget.qml` / `BoundedProcess.qml` (repo root) make up an
Omarchy bar-widget plugin (id `engine.cinque`) wrapping the CLI — a bar icon
(two overlapping squares) that opens a popup with the 5 slots, a detail view
per slot (name, commands, Launch / boot-slot / fluid-slot toggles), and an
edit view (rename, add/remove commands, Save). It reads
`~/.config/quattro-workstations` fresh every time the popup opens and calls
`quattro-workstation` for launch/boot-slot/fluid; there's no CLI subcommand to
unset boot-slot/fluid or to rename/edit commands, so those write the JSON
files directly, in the same shape the CLI itself reads and writes.

The edit view's add-command row is a `qs.Ui.SearchableDropdown` (the real
Omarchy searchable-combobox component) populated from `quattro-workstation
list-apps`, refreshed every time the edit view opens. Picking an app stores
its already-clean `command` string; "Custom command…" (first in the list)
reveals a plain text field for raw shell commands/scripts instead. Either way
storage is just `{command, workspace}` — a slot's existing commands (never
picked from the dropdown) edit exactly the same way, no migration needed.

Built against the real, installed `davedes.mouse-keybind-settings` plugin as
a reference for the manifest schema, the `qs.Ui`/`qs.Commons` theme tokens
(`bar.foreground`, `Style.*`), and how QML here shells out (a
`BoundedProcess.qml` wrapper around `Quickshell.Io.Process`, since Quickshell
has no built-in timeout/output-cap process type).

After editing `Widget.qml` directly in `~/.config/omarchy/plugins/engine.cinque/`
during development, `omarchy restart shell` is the reliable way to see the
change — Omarchy's file-watcher reload (`Local plugin changed, reloading:
engine.cinque` in `journalctl --user -f`) exists too, but a same-path edit
doesn't always get recompiled through it; a full shell restart always picks
up fresh QML.
