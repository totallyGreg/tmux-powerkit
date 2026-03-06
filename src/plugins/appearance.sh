#!/usr/bin/env bash
# =============================================================================
# Plugin: appearance
# Description: macOS appearance monitor and three-way toggle (auto/dark/light)
# Type: conditional (hidden on non-macOS)
# =============================================================================
#
# CONTRACT IMPLEMENTATION:
#
# State:
#   - active: Running on macOS
#   - inactive: Not on macOS
#
# Health:
#   - ok: Auto mode (following system)
#   - info: Forced dark or light mode
#
# Context:
#   - auto: Following system appearance
#   - dark: Forced dark mode
#   - light: Forced light mode
#
# Three-way toggle (keybinding_toggle / mouse_toggle):
#   auto → dark → light → auto
#
# This plugin acts as the tmux-side appearance watcher:
#   - In auto mode: reads defaults(1) each collect cycle, updates @dark_appearance
#     and sends SIGUSR1 to all zsh panes when the resolved value changes.
#     zac's USR1 handler in each pane then syncs its internal state.
#   - In forced mode: @powerkit_appearance_forced (dark|light) overrides the
#     system value; the toggle helper sets it via osascript + direct dispatch.
#
# =============================================================================

POWERKIT_ROOT="${POWERKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "${POWERKIT_ROOT}/src/contract/plugin_contract.sh"

# =============================================================================
# Plugin Contract: Metadata
# =============================================================================

plugin_get_metadata() {
  metadata_set "id" "appearance"
  metadata_set "name" "Appearance"
  metadata_set "description" "macOS appearance monitor with auto/dark/light toggle"
}

# =============================================================================
# Plugin Contract: Dependencies
# =============================================================================

plugin_check_dependencies() {
  is_macos || return 1
  require_cmd "defaults" || return 1
  return 0
}

# =============================================================================
# Plugin Contract: Options
# =============================================================================

plugin_declare_options() {
  # Icons per mode
  declare_option "icon_auto" "icon" $'\U000F101B' "Icon for auto mode (theme-light-dark)"
  declare_option "toggle_icon_auto" "icon" "🌗" "Icon for auto mode (theme-light-dark)"
  declare_option "icon_dark" "icon" $'\U000F0594' "Icon for dark mode (moon)"
  declare_option "toggle_icon_dark" "icon" "🌚" "Icon for dark mode (moon)"
  declare_option "icon_light" "icon" $'\U000F0599' "Icon for light mode (sun)"
  declare_option "toggle_icon_light" "icon" "🌞" "Icon for light mode (sun)"

  # Keybinding
  declare_option "keybinding_toggle" "key" "" "Keybinding to cycle appearance mode"
  declare_option "mouse_toggle" "bool" "false" "Enable mouse click on status-right to toggle appearance"

  # Cache
  declare_option "cache_ttl" "number" "0" "Cache duration in seconds"
}

# =============================================================================
# Plugin Contract: Data Collection
# =============================================================================

# Dispatch dark_val to @dark_appearance and signal all zsh processes.
# Uses appearance-dispatch if available (covers tmux panes + non-tmux sessions).
# Falls back to a manual tmux-panes-only USR1 loop.
_dispatch() {
  local dark_val="$1"
  local dispatch_bin="${HOME}/.config/zsh/.zcomet/repos/alberti42/zsh-appearance-control/bin/appearance-dispatch"

  tmux set-option -gq @dark_appearance "$dark_val" 2>/dev/null || true

  if [[ -x "$dispatch_bin" ]]; then
    "$dispatch_bin" tmux "$dark_val" 2>/dev/null || true
  else
    local pid comm
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      comm=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
      [[ "$comm" == *zsh ]] || continue
      kill -USR1 "$pid" 2>/dev/null || true
    done < <(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)
  fi
}

plugin_collect() {
  local auto_switch dark_style mode dark_val

  auto_switch=$(defaults read -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null) || auto_switch=""
  dark_style=$(defaults read -g AppleInterfaceStyle 2>/dev/null) || dark_style=""

  if [[ "$auto_switch" == "1" ]]; then
    mode="auto"
    [[ "$dark_style" == "Dark" ]] && dark_val=1 || dark_val=0
  elif [[ "$dark_style" == "Dark" ]]; then
    mode="dark"
    dark_val=1
  else
    mode="light"
    dark_val=0
  fi

  local last_dark
  last_dark=$(get_tmux_option "@dark_appearance" "")
  if [[ "$dark_val" != "$last_dark" ]]; then
    _dispatch "$dark_val"
    [[ -n "${_CACHE_DIR:-}" ]] && rm -f "${_CACHE_DIR}"/rendered_right__* 2>/dev/null || true
    tmux run-shell -b "sleep 0.5 && tmux refresh-client -S" 2>/dev/null || true
  fi

  plugin_data_set "mode" "$mode"
  plugin_data_set "dark" "$dark_val"
}

# =============================================================================
# Plugin Contract: Type and Presence
# =============================================================================

plugin_get_content_type() { printf 'dynamic'; }
plugin_get_presence() { printf 'conditional'; }

# =============================================================================
# Plugin Contract: State
# =============================================================================

plugin_get_state() {
  is_macos || {
    printf 'inactive'
    return
  }
  local mode
  mode=$(plugin_data_get "mode")
  [[ -n "$mode" ]] && printf 'active' || printf 'inactive'
}

# =============================================================================
# Plugin Contract: Health
# =============================================================================

plugin_get_health() {
  local mode
  mode=$(plugin_data_get "mode")
  case "$mode" in
    auto) printf 'ok' ;;
    *) printf 'good' ;;
  esac
}

# =============================================================================
# Plugin Contract: Context
# =============================================================================

plugin_get_context() {
  local mode
  mode=$(plugin_data_get "mode")
  printf '%s' "${mode:-auto}"
}

# =============================================================================
# Plugin Contract: Icon
# =============================================================================

plugin_get_icon() {
  local mode
  mode=$(plugin_data_get "mode")

  case "$mode" in
    dark) get_option "icon_dark" ;;
    light) get_option "icon_light" ;;
    *) get_option "icon_auto" ;;
  esac
}

# =============================================================================
# Plugin Contract: Render (plain text only)
# =============================================================================

plugin_render() {
  # printf '%s' "$(plugin_data_get "mode")"
  local mode
  mode=$(plugin_data_get "mode")

  case "$mode" in
    dark) get_option "toggle_icon_dark" ;;
    light) get_option "toggle_icon_light" ;;
    *) get_option "toggle_icon_auto" ;;
  esac
}

# =============================================================================
# Plugin Contract: Keybindings
# =============================================================================

plugin_setup_keybindings() {
  local toggle_key mouse helper_script
  helper_script="${POWERKIT_ROOT}/src/helpers/appearance_toggle.sh"
  [[ ! -x "$helper_script" ]] && chmod +x "$helper_script" 2>/dev/null

  toggle_key=$(get_option "keybinding_toggle")
  if [[ -n "$toggle_key" ]]; then
    register_keybinding "$toggle_key" "run-shell 'bash \"$helper_script\" toggle'"
  fi

  mouse=$(get_option "mouse_toggle")
  if [[ "$mouse" == "true" ]]; then
    pk_bind -n "MouseDown1StatusRight" "bash \"${helper_script}\" toggle"
  fi
}
