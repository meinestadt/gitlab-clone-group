#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 meinestadt.de GmbH, Author: Robert Wachtel
# See gitlab-clone-group.sh for the full license text.
set -euo pipefail

# Update all git repositories found recursively under a given directory.
# Fetches all remotes, fast-forwards the checked-out branch and every other
# local branch that is strictly behind its upstream. Never merges, rebases,
# resets or touches uncommitted/untracked files.
# Runs updates in parallel (multi-threaded) and reports failures at the end.
# Usage: ./update-repos.sh [directory] [max-parallel]
# Default directory: current working directory
# Default max-parallel: 8

ROOT_DIR="${1:-.}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
MAX_JOBS="${2:-8}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# Never prompt for credentials from a background job; English git messages for parsing
export GIT_TERMINAL_PROMPT=0 LC_MESSAGES=C

TMPDIR_RESULTS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESULTS"' EXIT

# Function run by each parallel job
update_repo() {
    local root_dir="$1"
    local results_dir="$2"
    local git_dir="$3"
    local repo_dir
    repo_dir="$(dirname "$git_dir")"
    local repo_name="${repo_dir#"$root_dir"/}"

    # git's error line (or else its first line)
    reason_of() { { grep -E '^(fatal|error):' <<< "$1" || grep -v '^$' <<< "$1"; } | head -1; }

    if [[ -z "$(git -C "$repo_dir" remote)" ]]; then
        echo "$repo_name" >> "$results_dir/skipped"
        echo "SKIP $repo_name (no remote)"
        return 0
    fi

    # Remote-tracking refs only; the working tree is not touched
    local output
    if ! output="$(git -C "$repo_dir" fetch --all --prune --quiet 2>&1)"; then
        printf '%s\t%s\t%s\n' "$repo_name" "-" "$(reason_of "$output")" >> "$results_dir/failed"
        echo "FAIL $repo_name (fetch)"
        return 0
    fi

    # Other local branches: fast-forward only. `fetch .` refuses non-fast-forward
    # updates and branches checked out in any worktree.
    local current branch upstream others=0
    current="$(git -C "$repo_dir" symbolic-ref --short -q HEAD || true)"
    while IFS=' ' read -r branch upstream; do
        [[ -z "$upstream" || "$branch" == "$current" ]] && continue
        git -C "$repo_dir" rev-parse -q --verify "refs/remotes/$upstream" >/dev/null || continue
        [[ "$(git -C "$repo_dir" rev-parse "refs/heads/$branch")" == "$(git -C "$repo_dir" rev-parse "refs/remotes/$upstream")" ]] && continue
        git -C "$repo_dir" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/$upstream" || continue
        if git -C "$repo_dir" fetch --quiet . "refs/remotes/$upstream:refs/heads/$branch" 2>/dev/null; then
            others=$((others + 1))
        fi
    done < <(git -C "$repo_dir" for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads)
    local extra=""
    [[ "$others" -gt 0 ]] && extra=", +$others other branch(es)"

    if [[ -z "$current" ]]; then
        echo "$repo_name" >> "$results_dir/skipped"
        echo "SKIP $repo_name (detached HEAD, fetched$extra)"
        return 0
    fi
    if ! git -C "$repo_dir" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        echo "$repo_name" >> "$results_dir/skipped"
        echo "SKIP $repo_name ($current has no upstream, fetched$extra)"
        return 0
    fi

    # Refuses if local changes would be overwritten or the branch has diverged
    if output="$(git -C "$repo_dir" merge --ff-only --quiet '@{u}' 2>&1)"; then
        echo "$repo_name" >> "$results_dir/success"
        echo "OK   $repo_name ($current$extra)"
    else
        printf '%s\t%s\t%s\n' "$repo_name" "$current" "$(reason_of "$output")" >> "$results_dir/failed"
        echo "FAIL $repo_name ($current)"
    fi
}

export -f update_repo

# Collect repos; skip dependency folders, trashed clones and .git internals (submodules)
repos=()
while IFS= read -r git_dir; do
    repos+=("$git_dir")
done < <(find "$ROOT_DIR" \
    \( -name node_modules -o -name .venv -o -name vendor -o -name target -o -name .trash \) -prune \
    -o -name .git -type d -print -prune 2>/dev/null)

total=${#repos[@]}
printf "Found %d repositories. Updating with up to %d parallel jobs...\n\n" "$total" "$MAX_JOBS"

# Initialize result files
touch "$TMPDIR_RESULTS/success" "$TMPDIR_RESULTS/skipped" "$TMPDIR_RESULTS/failed"

# Run updates in parallel using xargs
if [[ "$total" -gt 0 ]]; then
    # No -I: macOS xargs -I aborts on paths longer than 255 bytes; the path is appended last
    printf '%s\0' "${repos[@]}" | xargs -0 -n1 -P "$MAX_JOBS" bash -c 'update_repo "$@"' _ "$ROOT_DIR" "$TMPDIR_RESULTS"
fi

# Count results
success=$(wc -l < "$TMPDIR_RESULTS/success" | tr -d ' ')
skipped=$(wc -l < "$TMPDIR_RESULTS/skipped" | tr -d ' ')
failed_count=$(wc -l < "$TMPDIR_RESULTS/failed" | tr -d ' ')

printf "\n${BOLD}=== Summary ===${NC}\n"
printf "${GREEN}Updated: %d${NC} | ${YELLOW}Skipped: %d${NC} | ${RED}Failed: %d${NC}\n" "$success" "$skipped" "$failed_count"

# Print detailed failure report
if [[ "$failed_count" -gt 0 ]]; then
    printf "\n${BOLD}${RED}=== Failed Repositories ===${NC}\n\n"
    while IFS=$'\t' read -r repo_name branch reason; do
        printf "${RED}%-40s${NC} (branch: %s)\n" "$repo_name" "$branch"
        printf "  Reason: %s\n\n" "$reason"
    done < "$TMPDIR_RESULTS/failed"
fi
