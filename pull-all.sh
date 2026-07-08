#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Odoo Dev Environment — Pull All
# =============================================================================
# Fetch latest commits from origin for all vault repos, then fast-forward
# all worktrees to their respective remote branches.
#
# Usage:
#   make pull-all
#   (or directly: bash pull-all.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="${ODOO_VAULT_PATH:-$HOME/Odoo/.vault}"
WORKTREES_DIR="${ODOO_WORKTREE_PATH:-$HOME/Odoo/Worktrees}"
REPOS=(odoo enterprise design-themes)

source "$SCRIPT_DIR/lib/helpers.sh"

# --- Fetch -------------------------------------------------------------------
print_section "Fetching from origin"
echo ""

for repo in "${REPOS[@]}"; do
    if run_with_spinner "Fetching $repo..." \
        git -C "$VAULT_DIR/${repo}.git" fetch --prune origin \
            '+refs/heads/*:refs/remotes/origin/*'; then
        print_ok "$repo"
    else
        print_error "$repo — fetch failed. Check SSH access to GitHub."
        exit 1
    fi
done

# --- Update worktrees --------------------------------------------------------
echo ""
print_section "Updating worktrees"
echo ""

if [ ! -d "$WORKTREES_DIR" ]; then
    print_info "No worktrees found in $WORKTREES_DIR"
    echo ""
    exit 0
fi

found=0
for version_dir in "$WORKTREES_DIR"/*/; do
    [ -d "$version_dir" ] || continue
    version="$(basename "$version_dir")"
    if ! is_valid_version "$version"; then
        print_info "Skipping '$version' (not a valid version directory)"
        continue
    fi
    found=1
    echo -e "  ${BOLD}$version${NC}"
    for repo in "${REPOS[@]}"; do
        dest="$WORKTREES_DIR/$version/$repo"
        [ -d "$dest" ] || continue
        if git -C "$dest" reset --hard "origin/$version" > /dev/null 2>&1; then
            print_ok "$repo"
        else
            print_error "$repo (failed — check if origin/$version exists)"
        fi
    done
    echo ""
done

[ "$found" = "1" ] || { print_info "No worktrees found."; echo ""; }
