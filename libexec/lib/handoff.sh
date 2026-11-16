# shellcheck shell=bash
# Handoff_Dir location, shared by the handoff Commands (requirement 15).
dv_handoff_dir() {
  printf '%s/domovyk/handoff' "${XDG_STATE_HOME:-$HOME/.local/state}"
}
