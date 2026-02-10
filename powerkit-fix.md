  Summary

  Files modified (4):

  1. src/contract/pane_contract.sh — Core implementation:
    - _pane_resolve_color() — Added tmux format string
  passthrough (#{ detection returns color unresolved)
    - pane_flash_trigger() — Added trigger-time format
  evaluation via tmux display-message -p
    - pane_flash_setup() — Stores color in
  @_powerkit_pane_flash_resolved and delay in
  @_powerkit_pane_flash_delay; hook reads these at trigger
   time and evaluates format strings dynamically
    - _pane_flash_teardown() — Cleans up the two new tmux
  options
    - New _pane_flash_update_color() — Lightweight
  re-resolve for theme switches without re-registering the
   hook
  2. src/core/defaults.sh — Updated comment for
  POWERKIT_DEFAULT_PANE_FLASH_COLOR to document tmux
  format string support
  3. wiki/ContractPane.md — Added Color Resolution section
   with type table, dynamic light/dark example, updated
  flow diagram, and _pane_flash_update_color in API table
  4. tests/test_contracts.sh — Added
  _pane_flash_update_color to function existence checks

  Key design:

  - Static colors (theme names, hex) resolve at setup time
   into @_powerkit_pane_flash_resolved
  - Format strings (#{...}) pass through unresolved and
  evaluate via tmux display-message -p each time the hook
  fires
  - The shell escaping *\#\{* in the case pattern was
  verified to work correctly in the run-shell → sh
  execution chain
