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

# Read actual OS appearance: 1=dark, 0=light.
# defaults(1) returns "Dark" when dark; exits non-zero (key missing) when light
# or when macOS is set to Auto. Auto and explicit Light are indistinguishable.
_os_dark_value() {
    local style
    style=$(defaults read -g AppleInterfaceStyle 2>/dev/null) || style=""
    [[ "$style" == "Dark" ]] && printf '1' || printf '0'
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
        "$dispatch_bin" tmux   "$dark_val" 2>/dev/null || true
        "$dispatch_bin" cache  "$dark_val" 2>/dev/null || true
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
    local current next
    current=$(get_tmux_option "@powerkit_appearance_forced" "")
    [[ -z "$current" ]] && current="auto"

    case "$current" in
        auto)  next="dark"  ;;
        dark)  next="light" ;;
        light) next="auto"  ;;
        *)     next="auto"  ;;
    esac

    local dark_val
    case "$next" in
        dark)
            tmux set-option -gq @powerkit_appearance_forced "dark" 2>/dev/null
            # Change OS appearance first (synchronously), then dispatch so
            # zac's USR1 handler reads the updated OS state when it syncs.
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' 2>/dev/null
            dark_val=1
            ;;
        light)
            tmux set-option -gq @powerkit_appearance_forced "light" 2>/dev/null
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' 2>/dev/null
            dark_val=0
            ;;
        auto)
            tmux set-option -gq @powerkit_appearance_forced "" 2>/dev/null
            # Do not change OS appearance — leave macOS at whatever it is
            # (Auto/Light/Dark). Read the current resolved state.
            dark_val=$(_os_dark_value)
            ;;
    esac

    # Dispatch AFTER OS change so zac's USR1 handler sees the new appearance
    _dispatch "$dark_val"

    # Invalidate plugin data cache and render cache for immediate visual update
    cache_clear "plugin_appearance_data" 2>/dev/null || true
    cache_clear "plugin_appearance_ttl"  2>/dev/null || true
    [[ -n "${_CACHE_DIR:-}" ]] && rm -f "${_CACHE_DIR}"/rendered_right__* 2>/dev/null || true

    tmux refresh-client -S 2>/dev/null || true
    tmux run-shell -b "sleep 1 && tmux refresh-client -S" 2>/dev/null || true
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
