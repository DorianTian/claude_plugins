#!/bin/bash
set -euo pipefail

# Dorian's Claude Code Plugin Marketplace
# Usage: ./setup.sh [--check]
#
# What it does:
#   1. Register this repo as a Claude Code marketplace
#   2. Install local plugins (from ./plugins/)
#   3. Install external plugins (official LSP etc.) with their binaries

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/plugins.json"
MARKETPLACE_NAME="dorian-plugins"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}→${NC} $1"; }
log_ok()    { echo -e "${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
log_err()   { echo -e "${RED}✗${NC} $1"; }

# --------------- pre-checks ---------------

preflight() {
  if ! command -v claude &>/dev/null; then
    log_err "claude CLI not found. Install Claude Code first."
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    log_info "jq not found, installing via Homebrew..."
    brew install jq
  fi
}

# --------------- PATH ---------------

ensure_path() {
  local shell_rc="$HOME/.zshrc"
  local paths
  paths=$(jq -r '.path_additions // [] | .[]' "$CONFIG")

  [[ -z "$paths" ]] && return

  while IFS= read -r p; do
    local expanded="${p/#\$HOME/$HOME}"
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

# --------------- marketplace registration ---------------

register_marketplace() {
  if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
    log_ok "Marketplace '$MARKETPLACE_NAME' already registered"
  else
    log_info "Registering marketplace '$MARKETPLACE_NAME'..."
    claude plugin marketplace add "$SCRIPT_DIR" --name "$MARKETPLACE_NAME" 2>&1
    log_ok "Marketplace registered"
  fi
}

# --------------- local plugins (from this repo) ---------------

install_local_plugins() {
  local plugins_dir="$SCRIPT_DIR/plugins"
  local found=0

  for plugin_dir in "$plugins_dir"/*/; do
    [[ -d "$plugin_dir" ]] || continue
    local name
    name=$(basename "$plugin_dir")
    found=1

    local ref="${name}@${MARKETPLACE_NAME}"
    if claude plugin list 2>/dev/null | grep -q "$name.*$MARKETPLACE_NAME"; then
      log_ok "$ref — already installed"
    else
      log_info "$ref — installing..."
      if claude plugin install "$ref" 2>&1; then
        log_ok "$ref — installed"
      else
        log_err "$ref — installation failed"
      fi
    fi
  done

  [[ $found -eq 0 ]] && log_info "No local plugins yet"
}

# --------------- external plugins (official marketplace etc.) ---------------

install_external_plugins() {
  local count
  count=$(jq '.external_plugins // [] | length' "$CONFIG")

  [[ $count -eq 0 ]] && return

  log_info "Installing external plugins..."
  echo ""

  for ((i=0; i<count; i++)); do
    local name marketplace check_cmd install_cmd marketplace_source
    name=$(jq -r ".external_plugins[$i].name" "$CONFIG")
    marketplace=$(jq -r ".external_plugins[$i].marketplace" "$CONFIG")
    check_cmd=$(jq -r ".external_plugins[$i].binary.check // empty" "$CONFIG")
    install_cmd=$(jq -r ".external_plugins[$i].binary.install // empty" "$CONFIG")
    marketplace_source=$(jq -r ".external_plugins[$i].marketplace_source // empty" "$CONFIG")

    # register third-party marketplace if needed
    if [[ -n "$marketplace_source" ]]; then
      if ! claude plugin marketplace list 2>/dev/null | grep -q "$marketplace"; then
        log_info "Registering marketplace '$marketplace'..."
        claude plugin marketplace add "$marketplace_source" 2>&1
      fi
    fi

    # install binary if needed
    if [[ -n "$check_cmd" && -n "$install_cmd" ]]; then
      if command -v "$check_cmd" &>/dev/null; then
        log_ok "$name — binary ready ($(which "$check_cmd"))"
      else
        log_info "$name — installing binary..."
        if eval "$install_cmd" 2>&1; then
          ensure_path
          if command -v "$check_cmd" &>/dev/null; then
            log_ok "$name — binary installed"
          else
            log_warn "$name — binary not found in PATH after install"
          fi
        else
          log_err "$name — binary installation failed"
        fi
      fi
    fi

    # install Claude plugin
    local ref="${name}@${marketplace}"
    if claude plugin list 2>/dev/null | grep -q "$name"; then
      log_ok "$ref — plugin ready"
    else
      log_info "$ref — installing plugin..."
      if claude plugin install "$ref" 2>&1; then
        log_ok "$ref — installed"
      else
        log_err "$ref — plugin installation failed"
      fi
    fi
    echo ""
  done
}

# --------------- status check ---------------

check_status() {
  echo ""
  log_info "Status"
  echo "─────────────────────────────────────────"

  # marketplace
  echo -e "  ${CYAN}Marketplace${NC}"
  if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
    echo -e "    $MARKETPLACE_NAME: ${GREEN}✓${NC} registered"
  else
    echo -e "    $MARKETPLACE_NAME: ${RED}✗${NC} not registered"
  fi
  echo ""

  # local plugins
  echo -e "  ${CYAN}Local Plugins${NC}"
  local found_local=0
  for plugin_dir in "$SCRIPT_DIR/plugins"/*/; do
    [[ -d "$plugin_dir" ]] || continue
    found_local=1
    local name
    name=$(basename "$plugin_dir")
    if claude plugin list 2>/dev/null | grep -q "$name"; then
      echo -e "    $name: ${GREEN}✓${NC}"
    else
      echo -e "    $name: ${RED}✗${NC}"
    fi
  done
  [[ $found_local -eq 0 ]] && echo -e "    (none)"
  echo ""

  # external plugins
  echo -e "  ${CYAN}External Plugins${NC}"
  local count
  count=$(jq '.external_plugins // [] | length' "$CONFIG")

  for ((i=0; i<count; i++)); do
    local name check_cmd
    name=$(jq -r ".external_plugins[$i].name" "$CONFIG")
    check_cmd=$(jq -r ".external_plugins[$i].binary.check // empty" "$CONFIG")

    local b_status p_status
    if [[ -n "$check_cmd" ]] && command -v "$check_cmd" &>/dev/null; then
      b_status="${GREEN}✓${NC}"
    elif [[ -n "$check_cmd" ]]; then
      b_status="${RED}✗${NC}"
    else
      b_status="-"
    fi

    if claude plugin list 2>/dev/null | grep -q "$name"; then
      p_status="${GREEN}✓${NC}"
    else
      p_status="${RED}✗${NC}"
    fi

    echo -e "    $name  binary:$b_status  plugin:$p_status"
  done
  echo ""
}

# --------------- main ---------------

main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   Dorian's Claude Code Plugins           ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  preflight

  case "${1:-install}" in
    --check)
      ensure_path
      check_status
      ;;
    *)
      ensure_path
      register_marketplace
      echo ""
      install_local_plugins
      echo ""
      install_external_plugins
      log_info "Restart Claude Code to activate."
      check_status
      ;;
  esac
}

main "$@"
