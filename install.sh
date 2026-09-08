#!/usr/bin/env bash
# Cinque installer: CLI on PATH, default state, bar-widget plugin enabled,
# Hyprland boot/shutdown hooks wired in. Safe to re-run -- every step below
# checks its own "already done" condition first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN_ID="engine.cinque"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
QUATTRO_DIR="$HOME/.config/quattro-workstations"
BIN_DIR="$HOME/.local/bin"
HYPR_DIR="$HOME/.config/hypr"
AUTOSTART="$HYPR_DIR/autostart.lua"

BOOT_LINE='o.exec_on_start("quattro-workstation boot")'
SHUTDOWN_LINE='hl.on("hyprland.shutdown", function() hl.exec_cmd("quattro-workstation capture-fluid") end)'

check_dependencies() {
  local missing=()
  local cmd
  for cmd in python3 hyprctl omarchy jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "error: missing required command(s): ${missing[*]}" >&2
    echo "Cinque needs an Omarchy/Hyprland desktop (for hyprctl + the omarchy CLI)," >&2
    echo "plus python3 and jq. Install whatever's missing and re-run ./install.sh." >&2
    exit 1
  fi
}

install_cli() {
  mkdir -p "$BIN_DIR"
  ln -sf "$SCRIPT_DIR/bin/quattro-workstation" "$BIN_DIR/quattro-workstation"
  echo "CLI: symlinked bin/quattro-workstation -> $BIN_DIR/quattro-workstation"
}

init_state() {
  # quattro-workstation's own startup routine only ever creates files that
  # are missing -- an existing config.json / workstations/N.json is never
  # touched -- so just invoking it is the whole idempotent init.
  "$SCRIPT_DIR/bin/quattro-workstation" list >/dev/null
  echo "State: $QUATTRO_DIR ready (5 slots, no boot/fluid slot set, unless you already had one)"
}

install_plugin() {
  mkdir -p "$PLUGIN_DIR"
  # A real copy, not a symlink: the Omarchy plugin validator rejects
  # symlinks anywhere inside a plugin folder.
  cp -f "$SCRIPT_DIR/manifest.json" "$SCRIPT_DIR/Widget.qml" "$SCRIPT_DIR/BoundedProcess.qml" "$PLUGIN_DIR/"

  local validate_output
  if ! validate_output=$(omarchy plugin validate "$PLUGIN_DIR" 2>&1); then
    echo "error: plugin failed validation after copying to $PLUGIN_DIR:" >&2
    echo "$validate_output" >&2
    exit 1
  fi

  # `omarchy plugin add` only ever git-clones (it has no local-folder mode);
  # `enable` is the right call for a plugin already placed on disk, and is
  # itself idempotent -- re-running it on an already-enabled plugin just
  # re-affirms its placement.
  if ! omarchy plugin enable "$PLUGIN_ID" left >/dev/null; then
    echo "error: 'omarchy plugin enable $PLUGIN_ID' failed" >&2
    exit 1
  fi
  echo "Plugin: copied to $PLUGIN_DIR and enabled (left section of the bar)"
}

patch_autostart() {
  mkdir -p "$HYPR_DIR"
  if [[ ! -f "$AUTOSTART" ]]; then
    printf -- '-- Extra autostart processes.\n' > "$AUTOSTART"
  fi

  # Only ever take one backup: it exists to preserve what autostart.lua
  # looked like *before* Cinque ever touched it, so a second install run
  # (which would otherwise see its own prior edits as "the original")
  # must not overwrite it.
  if ! compgen -G "$AUTOSTART.bak.*" > /dev/null; then
    local backup="$AUTOSTART.bak.$(date +%Y%m%d%H%M%S)"
    cp "$AUTOSTART" "$backup"
    echo "Hooks: backed up autostart.lua -> $(basename "$backup")"
  fi

  if grep -qF "$BOOT_LINE" "$AUTOSTART" && grep -qF "$SHUTDOWN_LINE" "$AUTOSTART"; then
    echo "Hooks: already present in autostart.lua"
    return
  fi

  if ! grep -qF "$BOOT_LINE" "$AUTOSTART"; then
    printf '\n%s\n' "$BOOT_LINE" >> "$AUTOSTART"
  fi
  if ! grep -qF "$SHUTDOWN_LINE" "$AUTOSTART"; then
    printf '%s\n' "$SHUTDOWN_LINE" >> "$AUTOSTART"
  fi
  echo "Hooks: added boot/shutdown lines to autostart.lua"
}

reload_shell() {
  local old_pid new_pid
  old_pid=$(pgrep -x quickshell | head -n1 || true)

  if ! omarchy restart shell; then
    echo "error: 'omarchy restart shell' failed -- the plugin is installed but" >&2
    echo "may not be live yet; try running 'omarchy restart shell' yourself." >&2
    exit 1
  fi

  sleep 1
  new_pid=$(pgrep -x quickshell | head -n1 || true)
  if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]]; then
    echo "Reload: Omarchy shell restarted (pid $old_pid -> $new_pid), plugin is live now"
  else
    echo "warning: shell restart ran but a fresh process wasn't detected;" >&2
    echo "open the bar icon to check, or run 'omarchy restart shell' again." >&2
  fi
}

print_summary() {
  cat <<EOF

Cinque is installed.
  - CLI:     quattro-workstation (on your PATH via $BIN_DIR)
  - Plugin:  enabled on the bar's left section
  - Hooks:   boot/shutdown wired into $AUTOSTART

Click the two-squares icon on the bar to open it -- pick a slot, hit Edit,
and start adding apps from the picker. Nothing else to run.
EOF
}

main() {
  check_dependencies
  install_cli
  init_state
  install_plugin
  patch_autostart
  reload_shell
  print_summary
}

# Runs main only when executed directly, so this can also be sourced (e.g.
# by a test harness) to call individual steps without triggering the rest.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
