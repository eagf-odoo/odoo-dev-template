#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Odoo Dev Environment — Initial Machine Setup
# =============================================================================
# This script sets up the ~/Odoo/ directory structure, clones Odoo source
# repos as bare repositories, creates worktrees for selected versions,
# and installs upgrade tools.
#
# Usage: bash setup.sh
# Safe to re-run: existing directories and repos are skipped.
# =============================================================================

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODOO_BASE=~/Odoo
VAULT_DIR="$ODOO_BASE/.vault"
DATA_DIR="$ODOO_BASE/.data"
WORKTREES_DIR="$ODOO_BASE/Worktrees"
CUSTOMERS_DIR="$ODOO_BASE/Customers"
REPOS_DIR="$ODOO_BASE/Repos"
DUMPS_DIR="$ODOO_BASE/Dumps"
UPGRADE_DIR="$ODOO_BASE/Upgrade"
DOCKERFILES_DIR="$SCRIPT_DIR/dockerfiles"

# --- Helpers -----------------------------------------------------------------
source "$SCRIPT_DIR/lib/helpers.sh"

# --- Repos -------------------------------------------------------------------
ODOO_REPO="git@github.com:odoo/odoo.git"
ENTERPRISE_REPO="git@github.com:odoo/enterprise.git"
DESIGN_THEMES_REPO="git@github.com:odoo/design-themes.git"
UPGRADE_REPO="git@github.com:odoo/upgrade.git"
UPGRADE_UTIL_REPO="git@github.com:odoo/upgrade-util.git"
CLAUDE_MD_DIR="$ODOO_BASE/.claude-md"

# --- Versions ----------------------------------------------------------------
LEGACY_VERSIONS=("16.0" "17.0")
MODERN_VERSIONS=("18.0" "19.0")
ALL_VERSIONS=("${LEGACY_VERSIONS[@]}" "${MODERN_VERSIONS[@]}")

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}============================================${NC}"
  echo -e "${BOLD}${BLUE}  Odoo Dev Environment — Machine Setup${NC}"
  echo -e "${BOLD}${BLUE}============================================${NC}"
  echo ""
}

# --- 1. Prerequisites --------------------------------------------------------
check_prerequisites() {
  print_section "Checking prerequisites"
  local failed=0

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    print_ok "Docker Desktop is running"
  else
    print_error "Docker Desktop is not running — start it and re-run this script"
    failed=1
  fi

  if command -v git &>/dev/null; then
    print_ok "Git is installed ($(git --version | awk '{print $3}'))"
  else
    print_error "Git is not installed"
    failed=1
  fi

  local ssh_output
  ssh_output=$(ssh -T git@github.com 2>&1 || true)
  if echo "$ssh_output" | grep -q "successfully authenticated"; then
    print_ok "SSH access to GitHub is configured"
  else
    print_error "SSH access to GitHub failed — run: ssh -T git@github.com"
    failed=1
  fi

  if [ $failed -ne 0 ]; then
    echo ""
    echo -e "${RED}Fix the errors above and re-run the script.${NC}"
    exit 1
  fi
}

# --- 2. Directory structure --------------------------------------------------
create_directories() {
  print_section "Creating directory structure"

  local dirs=(
    "$VAULT_DIR"
    "$DATA_DIR"
    "$WORKTREES_DIR"
    "$CUSTOMERS_DIR"
    "$REPOS_DIR"
    "$DUMPS_DIR"
    "$UPGRADE_DIR"
  )

  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      print_skip "${dir/#$HOME/~}"
    else
      mkdir -p "$dir"
      print_ok "Created ${dir/#$HOME/~}"
    fi
  done
}

# --- 3. Bare repos -----------------------------------------------------------
USED_DONORS=()

expand_path() {
  local path="$1"
  echo "${path/#\~/$HOME}"
}

clone_vault() {
  print_section "Cloning bare repositories into .vault/"

  if [ -d "$VAULT_DIR/odoo.git" ] && [ -d "$VAULT_DIR/enterprise.git" ] && [ -d "$VAULT_DIR/design-themes.git" ]; then
    print_skip "All vault repos already present"
    return
  fi

  echo ""
  print_info "If you already have local clones of these repos, you can use them"
  print_info "as donors to avoid downloading from GitHub (saves time, same final size)."
  print_info "Donors can be deleted after setup completes."
  echo ""
  read -rp "  Do you have local clones to use as donors? [y/N]: " use_donors
  echo ""

  local donor_odoo="" donor_enterprise="" donor_themes=""

  if [[ "$use_donors" =~ ^[Yy]$ ]]; then
    read -rp "  Path to odoo clone          (Enter to download from GitHub): " donor_odoo
    read -rp "  Path to enterprise clone    (Enter to download from GitHub): " donor_enterprise
    read -rp "  Path to design-themes clone (Enter to download from GitHub): " donor_themes
    echo ""
    donor_odoo=$(expand_path "$donor_odoo")
    donor_enterprise=$(expand_path "$donor_enterprise")
    donor_themes=$(expand_path "$donor_themes")
  fi

  clone_bare() {
    local name="$1"
    local url="$2"
    local donor="$3"
    local dest="$VAULT_DIR/${name}.git"

    if [ -d "$dest" ]; then
      print_skip ".vault/${name}.git"
      return
    fi

    if [ -n "$donor" ] && [ -d "$donor" ]; then
      echo -e "  Cloning ${BOLD}${name}${NC} from local donor..."
      git clone --bare --local "$donor" "$dest"
      git -C "$dest" remote set-url origin "$url"
      git -C "$dest" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      run_with_spinner "Fetching updates for ${name} from GitHub..." \
        git -C "$dest" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune ||
        {
          print_error "fetch failed for ${name} — check your SSH access to GitHub"
          exit 1
        }
      print_ok ".vault/${name}.git (from donor)"
      USED_DONORS+=("$donor")
    else
      if [ -n "$donor" ]; then
        print_error "Donor path not found: $donor — downloading from GitHub instead"
      fi
      echo -e "  Cloning ${BOLD}${name}${NC} from GitHub..."
      git clone --bare "$url" "$dest"
      git -C "$dest" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      git -C "$dest" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune
      print_ok ".vault/${name}.git"
    fi
  }

  clone_bare "odoo" "$ODOO_REPO" "$donor_odoo"
  clone_bare "enterprise" "$ENTERPRISE_REPO" "$donor_enterprise"
  clone_bare "design-themes" "$DESIGN_THEMES_REPO" "$donor_themes"
}

# --- 3b. Donor cleanup -------------------------------------------------------
cleanup_donors() {
  [ ${#USED_DONORS[@]} -eq 0 ] && return

  echo ""
  print_section "Donor cleanup"
  print_info "The following donor repos are no longer needed:"
  for donor in "${USED_DONORS[@]}"; do
    echo -e "    ${YELLOW}${donor}${NC}"
  done
  echo ""
  read -rp "  Delete them now to free up disk space? [y/N]: " do_cleanup
  echo ""

  if [[ "$do_cleanup" =~ ^[Yy]$ ]]; then
    for donor in "${USED_DONORS[@]}"; do
      rm -rf "$donor"
      print_ok "Deleted $donor"
    done
  else
    print_info "Kept — you can delete them manually when ready"
  fi
}

# --- 4. Version selection ----------------------------------------------------
select_versions() {
  print_section "Select versions to install"

  # Auto-detect existing worktrees on re-run — skip the prompt
  local existing_versions=()
  for version in "${ALL_VERSIONS[@]}"; do
    if [ -d "$WORKTREES_DIR/$version/odoo" ]; then
      existing_versions+=("$version")
    fi
  done

  if [ ${#existing_versions[@]} -gt 0 ]; then
    SELECTED_VERSIONS=("${existing_versions[@]}")
    for version in "${SELECTED_VERSIONS[@]}"; do
      print_skip "Worktrees/$version (already installed)"
    done
    print_info "To add a new version: make worktree-add VERSION=X.0"
    return
  fi

  # First run — ask for version selection
  echo ""
  echo -e "  Available versions:"
  echo ""

  local i=1
  for version in "${ALL_VERSIONS[@]}"; do
    if is_legacy "$version"; then
      echo -e "    ${BOLD}$i)${NC} $version  ${YELLOW}(Python 3.10 — legacy)${NC}"
    else
      echo -e "    ${BOLD}$i)${NC} $version  ${GREEN}(Python 3.12)${NC}"
    fi
    ((i++))
  done

  echo ""
  echo -e "    ${BOLD}a)${NC} All versions"
  echo ""
  read -rp "  Enter numbers separated by spaces (e.g. 3 4) or 'a' for all: " selection
  echo ""

  SELECTED_VERSIONS=()

  if [[ "$selection" == "a" || "$selection" == "all" ]]; then
    SELECTED_VERSIONS=("${ALL_VERSIONS[@]}")
  else
    for num in $selection; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#ALL_VERSIONS[@]}" ]; then
        SELECTED_VERSIONS+=("${ALL_VERSIONS[$((num - 1))]}")
      else
        print_error "Invalid selection: $num — skipped"
      fi
    done
  fi

  if [ ${#SELECTED_VERSIONS[@]} -eq 0 ]; then
    print_error "No valid versions selected. Exiting."
    exit 1
  fi

  echo -e "  Installing: ${BOLD}${SELECTED_VERSIONS[*]}${NC}"
}

# --- 5. Worktrees ------------------------------------------------------------
create_worktrees() {
  print_section "Creating worktrees"

  for version in "${SELECTED_VERSIONS[@]}"; do
    echo ""
    echo -e "  ${BOLD}$version${NC}"

    for repo in odoo enterprise design-themes; do
      local dest="$WORKTREES_DIR/$version/$repo"
      if [ -d "$dest" ]; then
        print_skip "  Worktrees/$version/$repo"
      else
        git -C "$VAULT_DIR/${repo}.git" worktree add "$dest" "origin/$version"
        print_ok "  Worktrees/$version/$repo"
      fi
    done

    local dockerfile_dest="$WORKTREES_DIR/$version/Dockerfile"
    if [ -f "$dockerfile_dest" ]; then
      print_skip "  Worktrees/$version/Dockerfile"
    else
      if is_legacy "$version"; then
        cp "$DOCKERFILES_DIR/legacy.Dockerfile" "$dockerfile_dest"
      else
        cp "$DOCKERFILES_DIR/modern.Dockerfile" "$dockerfile_dest"
      fi
      print_ok "  Worktrees/$version/Dockerfile"
    fi
  done
}

# --- 6. Upgrade tools --------------------------------------------------------
setup_upgrade_tools() {
  print_section "Cloning upgrade tools"

  if [ -d "$UPGRADE_DIR/upgrade" ]; then
    print_skip "Upgrade/upgrade"
  else
    echo -e "  Cloning ${BOLD}upgrade${NC}..."
    git clone "$UPGRADE_REPO" "$UPGRADE_DIR/upgrade"
    print_ok "Upgrade/upgrade"
  fi

  if [ -d "$UPGRADE_DIR/upgrade-util" ]; then
    print_skip "Upgrade/upgrade-util"
  else
    echo -e "  Cloning ${BOLD}upgrade-util${NC}..."
    git clone "$UPGRADE_UTIL_REPO" "$UPGRADE_DIR/upgrade-util"
    print_ok "Upgrade/upgrade-util"
  fi
}

# --- 7. Docker images --------------------------------------------------------
# Docker images are built per-client via 'make build' from the client folder.
# Building here would be context-dependent and could cause 'check-image' to
# fail if the Docker context changes between setup and 'make start'.
# See WORKFLOWS.md section 6 for details.

# --- 8. CLAUDE.md system prompt (optional) -----------------------------------
CLAUDE_MD_SETUP=false

setup_claude_md() {
  print_section "AI Agent — CLAUDE.md system prompt (optional)"

  if [ -d "$CLAUDE_MD_DIR" ]; then
    print_skip ".claude-md/ (already installed)"
    CLAUDE_MD_SETUP=true
    return
  fi

  echo ""
  print_info "The AI agent requires a system prompt that gives Claude context about Odoo."
  print_info "It is installed once per machine at ~/Odoo/.claude-md/"
  echo ""
  read -rp "  Do you plan to use the AI agent (Claude Code)? [y/N]: " use_ai
  echo ""

  if [[ ! "$use_ai" =~ ^[Yy]$ ]]; then
    print_info "Skipped — run setup.sh again later, or set CLAUDE_PATH in .env to point at your own CLAUDE.md."
    echo ""
    return
  fi

  read -rp "  Git URL of your own CLAUDE.md repo (leave empty to skip): " claude_md_repo
  echo ""

  if [ -z "$claude_md_repo" ]; then
    print_info "Skipped — create ~/Odoo/.claude-md/CLAUDE.md yourself, or set CLAUDE_PATH in .env."
    echo ""
    return
  fi

  echo -e "  Cloning ${BOLD}CLAUDE.md${NC} system prompt..."
  git clone "$claude_md_repo" "$CLAUDE_MD_DIR"
  print_ok ".claude-md/"
  CLAUDE_MD_SETUP=true
}

# --- 9. Summary --------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}============================================${NC}"
  echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
  echo -e "${BOLD}${GREEN}============================================${NC}"
  echo ""
  echo -e "${BOLD}Installed versions:${NC}"
  for version in "${SELECTED_VERSIONS[@]}"; do
    echo -e "  ${GREEN}✓${NC} $version"
  done
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo -e "  1. Clone this template for your client:"
  echo -e "     ${CYAN}git clone git@github.com:eagf-odoo/odoo-dev-template.git ~/Odoo/Customers/<client>${NC}"
  echo -e "  2. Configure the environment:"
  echo -e "     ${CYAN}cp .env.example .env && \$EDITOR .env${NC}"
  echo -e "  3. Build the Docker image (first time per version):"
  echo -e "     ${CYAN}make build${NC}"
  echo -e "  4. Start the environment:"
  echo -e "     ${CYAN}make start${NC}"
  if [ "$CLAUDE_MD_SETUP" = true ]; then
    echo ""
    echo -e "${BOLD}AI Agent:${NC}"
    echo -e "  Add your Anthropic API key to .env, then run:"
    echo -e "     ${CYAN}make agent${NC}"
  fi
  echo ""
  echo -e "  See ${BOLD}WORKFLOWS.md${NC} for common day-to-day scenarios."
  echo ""
}

# --- Main --------------------------------------------------------------------
main() {
  print_header
  check_prerequisites
  create_directories
  clone_vault
  select_versions
  create_worktrees
  setup_upgrade_tools
  setup_claude_md
  cleanup_donors
  print_summary
}

main "$@"
