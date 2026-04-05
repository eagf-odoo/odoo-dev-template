#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Odoo Dev Environment — Worktree Manager
# =============================================================================
# Add or remove Odoo source worktrees (odoo, enterprise, design-themes).
#
# Usage:
#   bash worktree.sh              ← interactive menu
#   bash worktree.sh add 18.0     ← non-interactive add
#   bash worktree.sh add saas-18.4
#   bash worktree.sh remove 18.0  ← non-interactive remove
# =============================================================================

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Paths -------------------------------------------------------------------
ODOO_BASE=~/Odoo
VAULT_DIR="$ODOO_BASE/.vault"
WORKTREES_DIR="$ODOO_BASE/Worktrees"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILES_DIR="$SCRIPT_DIR/dockerfiles"

REPOS=(odoo enterprise design-themes)

# --- Helpers -----------------------------------------------------------------
print_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
print_skip()  { echo -e "  ${YELLOW}→${NC} $1 (already exists, skipping)"; }
print_error() { echo -e "  ${RED}✗${NC} $1"; }
print_info()  { echo -e "  ${BLUE}•${NC} $1"; }

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "${BOLD}${BLUE}  Odoo Dev Environment — Worktree Manager${NC}"
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo ""
}

is_legacy() {
    local version="$1"
    local major
    if [[ "$version" == saas-* ]]; then
        # Extract major from saas-X.Y → X
        major=$(echo "$version" | sed 's/saas-\([0-9]*\)\..*/\1/')
    else
        major=$(echo "$version" | cut -d'.' -f1)
    fi
    [[ "$major" -lt 18 ]]
}

validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]] && [[ ! "$version" =~ ^saas-[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Error: invalid version format '${version}'.${NC}"
        echo -e "${RED}Expected X.Y or saas-X.Y (e.g. 18.0, saas-18.4).${NC}"
        exit 1
    fi
}

check_vault() {
    for repo in "${REPOS[@]}"; do
        if [[ ! -d "$VAULT_DIR/${repo}.git" ]]; then
            print_error "Vault not found: $VAULT_DIR/${repo}.git"
            print_info  "Run setup.sh first to clone the bare repositories."
            exit 1
        fi
    done
}

check_connectivity() {
    nc -z -w 5 github.com 22 2>/dev/null
}

# --- Add ---------------------------------------------------------------------
cmd_add() {
    local version="${1:-}"

    if [[ -z "$version" ]]; then
        echo -e "  Examples: ${CYAN}18.0${NC}, ${CYAN}19.0${NC}, ${CYAN}saas-18.4${NC}"
        echo ""
        read -rp "  Version to create: " version
        echo ""
    fi

    validate_version "$version"
    check_vault

    # Fetch latest refs
    echo -e "  Fetching latest refs from origin..."
    echo ""
    if check_connectivity; then
        for repo in "${REPOS[@]}"; do
            echo -e "  ${BOLD}${repo}${NC}"
            git -C "$VAULT_DIR/${repo}.git" fetch --prune origin \
                && print_ok "fetched" \
                || { print_error "fetch failed — check your SSH access to GitHub"; exit 1; }
        done
    else
        print_error "Cannot reach GitHub (github.com:22 unreachable)"
        print_info  "The worktree will be created from the current vault state."
        echo ""
        read -rp "  Continue without fetching? [y/N]: " offline_confirm
        echo ""
        [[ "$offline_confirm" =~ ^[Yy]$ ]] || { print_info "Aborted."; exit 0; }
    fi

    # Create worktrees
    echo ""
    echo -e "  ${BOLD}Creating worktrees for $version${NC}"
    echo ""
    for repo in "${REPOS[@]}"; do
        local dest="$WORKTREES_DIR/$version/$repo"
        if [[ -d "$dest" ]]; then
            print_skip "Worktrees/$version/$repo"
        else
            git -C "$VAULT_DIR/${repo}.git" worktree add "$dest" "$version" 2>/dev/null \
                || git -C "$VAULT_DIR/${repo}.git" worktree add "$dest" "origin/$version"
            print_ok "Worktrees/$version/$repo"
        fi
    done

    # Copy Dockerfile
    echo ""
    local dockerfile_dest="$WORKTREES_DIR/$version/Dockerfile"
    if [[ -f "$dockerfile_dest" ]]; then
        print_skip "Worktrees/$version/Dockerfile"
    else
        if is_legacy "$version"; then
            cp "$DOCKERFILES_DIR/legacy.Dockerfile" "$dockerfile_dest"
            print_ok "Worktrees/$version/Dockerfile  ${YELLOW}(legacy — Python 3.10)${NC}"
        else
            cp "$DOCKERFILES_DIR/modern.Dockerfile" "$dockerfile_dest"
            print_ok "Worktrees/$version/Dockerfile  ${GREEN}(modern — Python 3.12)${NC}"
        fi
    fi

    echo ""
    echo -e "${BOLD}${GREEN}  Worktree $version ready!${NC}"
    echo ""
    echo -e "${BOLD}  Next steps:${NC}"
    echo -e "    Build the Docker image:"
    echo -e "    ${CYAN}docker build -t odoo-dev:$version ~/Odoo/Worktrees/$version${NC}"
    echo ""
}

# --- Remove ------------------------------------------------------------------
cmd_remove() {
    local version="${1:-}"

    # List existing worktrees
    local existing=()
    if [[ -d "$WORKTREES_DIR" ]]; then
        while IFS= read -r dir; do
            existing+=("$(basename "$dir")")
        done < <(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    fi

    if [[ ${#existing[@]} -eq 0 ]]; then
        print_error "No worktrees found in $WORKTREES_DIR"
        exit 1
    fi

    if [[ -z "$version" ]]; then
        echo -e "  Existing worktrees:"
        echo ""
        local i=1
        for v in "${existing[@]}"; do
            echo -e "    ${BOLD}$i)${NC} $v"
            ((i++))
        done
        echo ""
        read -rp "  Number to remove: " selection
        echo ""

        if [[ ! "$selection" =~ ^[0-9]+$ ]] || \
           [[ "$selection" -lt 1 ]] || \
           [[ "$selection" -gt "${#existing[@]}" ]]; then
            print_error "Invalid selection."
            exit 1
        fi

        version="${existing[$((selection - 1))]}"
    fi

    # Confirm
    echo -e "  ${YELLOW}This will permanently remove Worktrees/${version} and its git worktree registrations.${NC}"
    echo ""
    read -rp "  Are you sure? [y/N]: " confirm
    echo ""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Aborted."
        exit 0
    fi

    check_vault

    # Remove git worktrees
    echo -e "  ${BOLD}Removing worktrees for $version${NC}"
    echo ""
    for repo in "${REPOS[@]}"; do
        local dest="$WORKTREES_DIR/$version/$repo"
        if [[ -d "$dest" ]]; then
            git -C "$VAULT_DIR/${repo}.git" worktree remove --force "$dest"
            print_ok "removed Worktrees/$version/$repo"
        else
            print_skip "Worktrees/$version/$repo (not found)"
        fi
    done

    # Remove remaining files (Dockerfile, etc.)
    local version_dir="$WORKTREES_DIR/$version"
    if [[ -d "$version_dir" ]]; then
        rm -rf "$version_dir"
        print_ok "removed Worktrees/$version"
    fi

    echo ""
    echo -e "${BOLD}${GREEN}  Worktree $version removed.${NC}"
    echo ""
}

# --- Main --------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    local version="${2:-}"

    print_header

    if [[ -n "$cmd" ]]; then
        case "$cmd" in
            add)    cmd_add    "$version" ;;
            remove) cmd_remove "$version" ;;
            *)
                echo -e "${RED}Unknown command: $cmd${NC}"
                echo -e "Usage: bash worktree.sh [add|remove] [version]"
                exit 1
                ;;
        esac
        return
    fi

    # Interactive menu
    echo -e "  What do you want to do?"
    echo ""
    echo -e "    ${BOLD}1)${NC} Add a worktree"
    echo -e "    ${BOLD}2)${NC} Remove a worktree"
    echo ""
    read -rp "  Choice [1/2]: " choice
    echo ""

    case "$choice" in
        1) cmd_add    "" ;;
        2) cmd_remove "" ;;
        *)
            print_error "Invalid choice."
            exit 1
            ;;
    esac
}

main "$@"
