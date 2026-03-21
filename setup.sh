#!/bin/bash
set -euo pipefail

# Dorian's Claude Code Plugin Setup
# Usage: ./setup.sh [--binaries-only | --plugins-only | --check]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGINS_JSON="$SCRIPT_DIR/plugins.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}→${NC} $1"; }
log_ok()    { echo -e "${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
log_err()   { echo -e "${RED}✗${NC} $1"; }

# --------------- dependency check ---------------

check_jq() {
  if ! command -v jq &>/dev/null; then
    log_info "jq not found, installing via Homebrew..."
    if command -v brew &>/dev/null; then
      brew install jq
    else
      log_err "jq is required but Homebrew is not available. Install jq manually."
      exit 1
    fi
  fi
}

check_claude() {
  if ! command -v claude &>/dev/null; then
    log_err "claude CLI not found. Install Claude Code first."
    exit 1
  fi
}

# --------------- PATH helpers ---------------

ensure_path() {
  local shell_rc="$HOME/.zshrc"
  local paths
  paths=$(jq -r '.path_additions[]' "$PLUGINS_JSON")

  while IFS= read -r p; do
    local expanded="${p/#\$HOME/$HOME}"
    # normalize: strip $HOME and ~/  for robust grep matching
    local pattern="${expanded/#$HOME/}"
    if ! echo "$PATH" | tr ':' '\n' | grep -qF "$expanded"; then
      if ! grep -q "$pattern" "$shell_rc" 2>/dev/null; then
        echo "export PATH=\"\$PATH:$p\"" >> "$shell_rc"
        log_ok "Added $p to $shell_rc"
      fi
      export PATH="$PATH:$expanded"
    fi
  done <<< "$paths"
}

# --------------- binary installation ---------------

install_binaries() {
  log_info "Installing language server binaries..."
  echo ""

  local count
  count=$(jq '.plugins | length' "$PLUGINS_JSON")

  for ((i=0; i<count; i++)); do
    local name check_cmd install_cmd
    name=$(jq -r ".plugins[$i].name" "$PLUGINS_JSON")
    check_cmd=$(jq -r ".plugins[$i].binary.check" "$PLUGINS_JSON")
    install_cmd=$(jq -r ".plugins[$i].binary.install" "$PLUGINS_JSON")

    if command -v "$check_cmd" &>/dev/null; then
      log_ok "$name — binary already installed ($(which "$check_cmd"))"
    else
      log_info "$name — installing binary..."
      if eval "$install_cmd" 2>&1; then
        # re-check after install (some binaries land in path_hint dirs)
        ensure_path
        if command -v "$check_cmd" &>/dev/null; then
          log_ok "$name — binary installed"
        else
          log_warn "$name — install ran but binary not found in PATH"
        fi
      else
        log_err "$name — binary installation failed"
      fi
    fi
  done
  echo ""
}

# --------------- plugin installation ---------------

install_plugins() {
  log_info "Installing Claude Code plugins..."
  echo ""

  local count
  count=$(jq '.plugins | length' "$PLUGINS_JSON")

  for ((i=0; i<count; i++)); do
    local name marketplace
    name=$(jq -r ".plugins[$i].name" "$PLUGINS_JSON")
    marketplace=$(jq -r ".plugins[$i].marketplace" "$PLUGINS_JSON")

    local plugin_ref="${name}@${marketplace}"

    # check if already installed
    if claude plugin list 2>/dev/null | grep -q "$name"; then
      log_ok "$plugin_ref — already installed"
    else
      log_info "$plugin_ref — installing..."
      if claude plugin install "$plugin_ref" 2>&1; then
        log_ok "$plugin_ref — installed"
      else
        log_err "$plugin_ref — installation failed"
      fi
    fi
  done
  echo ""
}

# --------------- status check ---------------

check_status() {
  echo ""
  log_info "Plugin status check"
  echo "─────────────────────────────────────────"

  local count
  count=$(jq '.plugins | length' "$PLUGINS_JSON")

  for ((i=0; i<count; i++)); do
    local name check_cmd marketplace desc
    name=$(jq -r ".plugins[$i].name" "$PLUGINS_JSON")
    check_cmd=$(jq -r ".plugins[$i].binary.check" "$PLUGINS_JSON")
    marketplace=$(jq -r ".plugins[$i].marketplace" "$PLUGINS_JSON")
    desc=$(jq -r ".plugins[$i].description" "$PLUGINS_JSON")

    local binary_status plugin_status

    if command -v "$check_cmd" &>/dev/null; then
      binary_status="${GREEN}✓${NC}"
    else
      binary_status="${RED}✗${NC}"
    fi

    if claude plugin list 2>/dev/null | grep -q "$name"; then
      plugin_status="${GREEN}✓${NC}"
    else
      plugin_status="${RED}✗${NC}"
    fi

    echo -e "  $name"
    echo -e "    Binary: $binary_status  Plugin: $plugin_status"
    echo -e "    ${CYAN}$desc${NC}"
    echo ""
  done
}

# --------------- main ---------------

main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   Dorian's Claude Code Plugin Setup      ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  check_jq
  check_claude

  case "${1:-all}" in
    --binaries-only)
      ensure_path
      install_binaries
      ;;
    --plugins-only)
      install_plugins
      ;;
    --check)
      ensure_path
      check_status
      ;;
    all|*)
      ensure_path
      install_binaries
      install_plugins
      log_info "Restart Claude Code to activate LSP plugins."
      check_status
      ;;
  esac
}

main "$@"
