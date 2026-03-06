#!/usr/bin/env bash
# =============================================================================
# Helper: appearance_toggle
# Description: Cycles macOS appearance mode: auto → dark → light → auto
# Type: command
# =============================================================================

. "$(dirname "${BASH_SOURCE[0]}")/../contract/helper_contract.sh"
helper_init

# =============================================================================
# Metadata
# =============================================================================

helper_get_metadata() {
    helper_metadata_set "id"          "appearance_toggle"
    helper_metadata_set "name"        "Appearance Toggle"
    helper_metadata_set "description" "Cycle macOS appearance mode: auto → dark → light → auto"
    helper_metadata_set "type"        "command"
}

helper_get_actions() {
    echo "toggle - Cycle appearance mode (auto → dark → light → auto)"
}

# =============================================================================
# Internal Helpers
# =============================================================================

# Read the actual macOS three-state: auto | dark | light
_macos_mode() {
    local auto_switch dark_style
    auto_switch=$(defaults read -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null) || auto_switch=""
    dark_style=$(defaults read -g AppleInterfaceStyle 2>/dev/null) || dark_style=""

    if [[ "$auto_switch" == "1" ]]; then
        printf 'auto'
    elif [[ "$dark_style" == "Dark" ]]; then
        printf 'dark'
    else
        printf 'light'
    fi
}

# Dispatch dark_val (0|1) to @dark_appearance and signal all zsh processes.
# Uses appearance-dispatch if available (handles both tmux panes AND non-tmux
# zsh sessions registered in ~/.cache/zac/pids/). Falls back to a manual
# tmux-panes-only USR1 loop.
_dispatch() {
    local dark_val="$1"
    local dispatch_bin="${HOME}/.config/zsh/.zcomet/repos/alberti42/zsh-appearance-control/bin/appearance-dispatch"

    tmux set-option -gq @dark_appearance "$dark_val" 2>/dev/null || true

    if [[ -x "$dispatch_bin" ]]; then
        "$dispatch_bin" tmux "$dark_val" 2>/dev/null || true
    else
        # Fallback: signal only tmux panes
        local pid comm
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            comm=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
            [[ "$comm" == *zsh ]] || continue
            kill -USR1 "$pid" 2>/dev/null || true
        done < <(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)
    fi
}

# =============================================================================
# Actions
# =============================================================================

_do_toggle() {
    local current next dark_val dark_style
    current=$(_macos_mode)

    case "$current" in
        auto)  next="dark"  ;;
        dark)  next="light" ;;
        light) next="auto"  ;;
        *)     next="auto"  ;;
    esac

    case "$next" in
        dark)
            defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null || true
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' 2>/dev/null
            dark_val=1
            ;;
        light)
            defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null || true
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' 2>/dev/null
            dark_val=0
            ;;
        auto)
            defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool true 2>/dev/null
            dark_style=$(defaults read -g AppleInterfaceStyle 2>/dev/null) || dark_style=""
            [[ "$dark_style" == "Dark" ]] && dark_val=1 || dark_val=0
            ;;
    esac

    _dispatch "$dark_val"

    cache_clear "plugin_appearance_data" 2>/dev/null || true
    cache_clear "plugin_appearance_ttl"  2>/dev/null || true
    [[ -n "${_CACHE_DIR:-}" ]] && rm -f "${_CACHE_DIR}"/rendered_right__* 2>/dev/null || true

    bash "${POWERKIT_ROOT}/tmux-powerkit.tmux" 2>/dev/null || true
}

# =============================================================================
# Helper Contract: Main Entry Point
# =============================================================================

helper_main() {
    local action="${1:-toggle}"
    case "$action" in
        toggle) _do_toggle ;;
        *) printf 'appearance_toggle: unknown action: %s\n' "$action" >&2; return 1 ;;
    esac
}

helper_dispatch "$@"
