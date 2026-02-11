---
title: Fix pane flash color to sync with macOS appearance changes
type: fix
date: 2026-02-11
---

# Fix Pane Flash Color Appearance Synchronization

## Overview

The pane flash feature has dynamic color auto-generation that works correctly, but `@dark_appearance` is never updated when macOS switches between light/dark modes. This causes the flash color to be "stuck" on whichever value was set at startup.

**Current behavior:**
- Format string evaluation works: `#{?#{@dark_appearance},#073642,#eee8d5}` ✅
- Auto-generation creates correct format strings ✅
- BUT: `@dark_appearance` stays at `0` even when macOS switches to dark ❌

**Root cause:**
- Ghostty terminal auto-switches themes based on system appearance (native integration)
- BUT Ghostty has no hooks system to execute commands when themes switch
- The tmux option `@dark_appearance` is statically set in tmux.conf and never updates
- Result: Ghostty theme switches, but pane flash color stays stuck

## Problem Statement

Users with Ghostty terminal (and other terminals without command execution hooks) experience pane flash colors that don't match the current theme because there's no mechanism to keep `@dark_appearance` synchronized with macOS system appearance.

The existing feature branch `feature/dynamic-pane-flash-color` implements the format string evaluation correctly, but is missing the synchronization mechanism.

## Proposed Solution

Implement a **hybrid approach**: automatic sync on startup + manual sync command + optional shell prompt integration.

### Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    macOS System Appearance                   │
│                  (Dark ↔ Light via Time/Manual)              │
│                           ↓                                  │
│                    Ghostty Auto-Switches                     │
│              (theme = light:...,dark:...)                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      │ ① Auto-detect on startup
                      │ ② Manual sync via keybinding
                      │ ③ Optional: shell prompt integration
                      ▼
┌─────────────────────────────────────────────────────────────┐
│          sync_appearance_with_system()                       │
│   • Reads: defaults read -g AppleInterfaceStyle             │
│   • Sets: tmux set -g @dark_appearance <0|1>                │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              @dark_appearance (tmux option)                  │
│                    0 = Light, 1 = Dark                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│         pane_flash_trigger() - evaluates format string       │
│   #{?#{@dark_appearance},#073642,#eee8d5}                   │
│                                                              │
│   If @dark_appearance=1 → #073642 (dark)                    │
│   If @dark_appearance=0 → #eee8d5 (light)                   │
└─────────────────────────────────────────────────────────────┘
```

### Components to Implement

#### 1. Appearance Detection Function

**Location**: `src/utils/platform.sh`

```bash
# Detect current macOS appearance mode
# Returns: 0 (light) or 1 (dark)
get_macos_appearance() {
    if ! is_macos; then
        echo "0"  # Default to light on non-macOS
        return
    fi

    local appearance
    appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)

    if [[ "$appearance" == "Dark" ]]; then
        echo "1"
    else
        echo "0"
    fi
}
```

#### 2. Sync Command

**Location**: `src/contract/pane_contract.sh`

```bash
# Sync @dark_appearance with current system appearance
# Usage: sync_pane_flash_appearance
sync_pane_flash_appearance() {
    local system_appearance
    system_appearance=$(get_macos_appearance)

    local current_setting
    current_setting=$(get_tmux_option "@dark_appearance" "0")

    if [[ "$system_appearance" != "$current_setting" ]]; then
        set_tmux_option "@dark_appearance" "$system_appearance"
        log_info "pane" "Synced @dark_appearance: $current_setting → $system_appearance"

        # Update the resolved color (triggers re-evaluation of format string)
        if declare -F _pane_flash_update_color &>/dev/null; then
            _pane_flash_update_color
        fi
    fi
}
```

#### 3. Bootstrap Integration

**Location**: `src/core/bootstrap.sh` (in `powerkit_bootstrap()`)

Add after theme loading, before `pane_flash_setup()`:

```bash
# Sync @dark_appearance with system (auto-detect on startup)
if declare -F sync_pane_flash_appearance &>/dev/null; then
    sync_pane_flash_appearance
fi
```

#### 4. Keybinding for Manual Sync

**Location**: Add to keybindings system or tmux.conf

Add configurable keybinding:

```tmux
# Default: prefix + A (for Appearance sync)
set -g @powerkit_appearance_sync_key "A"

# Implementation in keybindings.sh or as simple binding:
bind-key A run-shell 'tmux set -g @dark_appearance $(defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q Dark && echo 1 || echo 0) ; tmux display-message "Appearance synced"'
```

### Implementation Strategy

**Phase 1: Core Detection (Task #2)**
1. Implement `get_macos_appearance()` in platform.sh
2. Add unit tests for detection logic
3. Verify it works on macOS (Dark and Light modes)

**Phase 2: Sync Command (Task #3)**
1. Implement `sync_pane_flash_appearance()` function
2. Add logging for debugging
3. Test manual invocation works

**Phase 3: Automatic Sync (Task #4)**
1. Integrate sync into bootstrap (on startup)
2. Ensure it runs before `pane_flash_setup()`
3. Test tmux reload picks up current appearance

**Phase 4: Optional Enhancements (Task #1)**
1. Research shell prompt integration (update on every prompt)
2. Consider fswatch daemon for advanced users
3. Evaluate performance trade-offs

**Phase 5: Testing & Documentation (Tasks #5-6)**
1. End-to-end testing with appearance changes
2. Test with multiple themes
3. Update CLAUDE.md and wiki documentation
4. Add troubleshooting guide

## Technical Considerations

### Performance

- `defaults read` is fast (~5-10ms on modern Macs)
- Only called on startup + manual trigger (no polling)
- No constant overhead
- Format string evaluation is native tmux (very fast)

### Edge Cases

1. **Non-macOS systems**: Return default value (light mode), no errors
2. **Terminal not Ghostty**: Still works, provides manual sync option
3. **WezTerm users with hooks**: Their hooks still work, this is additive
4. **Theme without light/dark variants**: Auto-generation skips, uses current variant
5. **User toggles appearance while in tmux**: Manual keybinding syncs immediately

### Backwards Compatibility

- ✅ Existing auto-generation code unchanged
- ✅ Format string evaluation unchanged
- ✅ Users with WezTerm hooks unaffected
- ✅ Can disable pane flash entirely if desired
- ✅ Falls back gracefully on non-macOS

## Acceptance Criteria

### Functional Requirements

- [ ] `get_macos_appearance()` returns correct value (0 or 1)
- [ ] `sync_pane_flash_appearance()` updates @dark_appearance
- [ ] Sync runs automatically on tmux startup/reload
- [ ] Manual keybinding syncs appearance on demand
- [ ] Pane flash color matches current macOS appearance after sync
- [ ] Works with all themes that have light/dark variants

### Non-Functional Requirements

- [ ] Sync operation completes in < 50ms
- [ ] No polling or background processes
- [ ] No impact on pane switching performance
- [ ] Logging provides clear debugging info
- [ ] Documentation explains Ghostty-specific setup

### Quality Gates

- [ ] Tested with macOS Dark mode → sync → Light mode
- [ ] Tested with macOS Light mode → sync → Dark mode
- [ ] Tested tmux reload picks up current appearance
- [ ] Tested manual keybinding works
- [ ] Tested with solarized light/dark
- [ ] No regressions in existing pane flash behavior

## Success Metrics

- Pane flash color correctly matches macOS appearance after sync
- Users can manually sync with a single keybinding
- No noticeable performance impact
- Clear documentation for Ghostty users

## Dependencies & Prerequisites

- Requires macOS (for `defaults read` command)
- Requires tmux-powerkit `feature/dynamic-pane-flash-color` branch
- Requires `@dark_appearance` support in tmux.conf
- Requires themes with light/dark variants for auto-generation

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `defaults read` slow on older Macs | Low | Low | Only called on startup, not in hot path |
| Users forget to sync manually | Medium | Low | Auto-sync on startup covers most cases; add to docs |
| Format string breaks on old tmux | Low | Medium | Test on tmux 3.0+ (minimum requirement) |
| Non-macOS users see errors | Low | Low | Graceful fallback to default value |

## Alternative Approaches Considered

### Option 1: Remove Auto-Generation (REJECTED)

**Pros**: Simplest, no sync needed
**Cons**: Loses dynamic appearance adaptation feature

**Why rejected**: Feature is valuable and already implemented; just needs sync mechanism

### Option 2: Polling Every 30s (REJECTED)

**Pros**: Fully automatic, no user interaction
**Cons**: Performance overhead, constant background work, battery impact

**Why rejected**: Violates design principle of no constant polling

### Option 3: Shell Prompt Integration Only (CONSIDERED)

**Pros**: Updates frequently (every prompt), no keybinding needed
**Cons**: Requires shell hook, more complex setup, not all users use zsh

**Why considered**: Could be offered as optional enhancement for advanced users

### Option 4: fswatch Daemon (CONSIDERED)

**Pros**: Instant updates, no user interaction
**Cons**: Requires external tool, complex setup, system resource usage

**Why considered**: Could be documented as advanced option for power users

**Decision**: Hybrid approach (auto on startup + manual keybinding) provides best balance of automation, simplicity, and performance.

## Future Considerations

### Potential Enhancements

1. **Shell prompt integration**: Update `@dark_appearance` in precmd/PROMPT_COMMAND hook
   - Add to zsh-appearance-control callback
   - Update every time prompt redraws
   - Zero user interaction needed

2. **fswatch daemon**: Watch macOS preferences file for changes
   - Instant updates when appearance switches
   - Requires fswatch installation
   - Advanced users only

3. **Terminal escape sequences**: Detect appearance via ANSI codes
   - If terminals add support in future
   - Would work across all terminals

4. **Ghostty feature request**: Request appearance change hooks
   - File issue on ghostty-org/ghostty
   - Would benefit all Ghostty users

### Extensibility

The sync mechanism is generic enough to work with:
- Any terminal emulator (not just Ghostty)
- Any theme that uses `@dark_appearance`
- Other plugins that need appearance awareness
- Can be called from external scripts/tools

## Documentation Plan

### CLAUDE.md Updates

- Document `sync_pane_flash_appearance()` function in API Reference
- Add "Appearance Synchronization" subsection under Pane Contract
- Document Ghostty-specific setup in Pane Flash section
- Update troubleshooting for "flash color stuck"

### Wiki Updates

- Add "Appearance Synchronization" section to ContractPane.md
- Document the keybinding in Configuration.md
- Add Ghostty example in Quick-Start.md
- Update Troubleshooting.md with sync instructions

### README Updates

- Mention appearance sync feature in Features section
- Add note about Ghostty compatibility in Platform Support
- Include keybinding in Quick Start examples

## Implementation Checklist

### Code Changes

- [ ] Write `get_macos_appearance()` in src/utils/platform.sh
- [ ] Write `sync_pane_flash_appearance()` in src/contract/pane_contract.sh
- [ ] Integrate sync into src/core/bootstrap.sh (before pane_flash_setup)
- [ ] Add keybinding configuration option
- [ ] Register keybinding in keybindings system

### Testing

- [ ] Test `get_macos_appearance()` returns correct values
- [ ] Test with macOS Dark mode, verify @dark_appearance=1
- [ ] Test with macOS Light mode, verify @dark_appearance=0
- [ ] Test tmux reload syncs appearance
- [ ] Test manual keybinding syncs on demand
- [ ] Test pane flash shows correct color after sync
- [ ] Test with solarized light/dark theme
- [ ] Test with catppuccin latte/mocha theme
- [ ] Test on non-macOS (graceful fallback)

### Documentation

- [ ] Update CLAUDE.md with sync function and Ghostty notes
- [ ] Update wiki/ContractPane.md with sync documentation
- [ ] Update README.md with feature mention
- [ ] Add troubleshooting section for "colors don't match"
- [ ] Document the keybinding and manual sync option

### Cleanup

- [ ] Remove dynamic-color-analysis.md (temporary file)
- [ ] Remove powerkit-fix.md (temporary file)
- [ ] Review uncommitted changes
- [ ] Create clean commit with conventional format (no emoji)
- [ ] Update commit message to reference this plan

## References

### Internal Documentation

- `CLAUDE.md` - Pane Contract section (lines 1700-2046)
- `dynamic-color-analysis.md` - Problem analysis
- `src/contract/pane_contract.sh` - Current implementation

### External Resources

- [zsh-appearance-control](https://github.com/alberti42/zsh-appearance-control) - Reference implementation
- [Ghostty Theme Documentation](https://ghostty.org/docs/features/theme) - Native theme switching
- [tmux Format Strings](https://man.openbsd.org/tmux#FORMATS) - Conditional syntax reference

### Related Work

- Branch: `feature/dynamic-pane-flash-color`
- Original issue: Pane flash color stuck on initial value
- Root cause: `@dark_appearance` not synchronized with macOS
- Solution: Add sync mechanism (auto + manual)

---

## Summary

The fix is straightforward: add a sync mechanism to keep `@dark_appearance` updated with macOS system appearance. The feature branch already has working format string evaluation—we just need to feed it the correct value.

**Three-part solution:**

1. **Auto-sync on startup** - Detects macOS appearance and sets @dark_appearance when tmux starts/reloads
2. **Manual keybinding** - Single keypress (prefix + A) to sync when appearance changes during session
3. **Optional prompt integration** - For advanced users who want instant updates every prompt

This provides a clean, performant solution that works with Ghostty (and any terminal without command execution hooks) while maintaining backwards compatibility with WezTerm-style hook integrations.

**Key insight**: Ghostty automatically switches its own theme based on system appearance, but can't notify tmux. Our sync mechanism bridges this gap, allowing the pane flash to follow along with Ghostty's automatic theme switching.
