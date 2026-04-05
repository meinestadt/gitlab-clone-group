#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# MIT License
#
# Copyright (c) 2026 meinestadt.de GmbH
# Author: Robert Wachtel
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -euo pipefail

###############################################################################
# Clone all projects from a GitLab group into a local directory,
# preserving namespace structure.
# Requires: glab (authenticated), python3, git
#
# Mandatory configuration (flag or environment variable):
#   --host   HOST   GitLab hostname          / GITLAB_CLONE_HOST
#   --group  ID     GitLab group ID or path  / GITLAB_CLONE_GROUP_ID
#   --dir    PATH   Local target directory   / GITLAB_CLONE_TARGET_DIR
#
# Usage: clone-gitlab-group.sh --host HOST --group ID --dir PATH [OPTIONS]
#
# Options:
#   --host   HOST         GitLab hostname (e.g. gitlab.example.com)
#   --group  ID           GitLab group ID or path (e.g. 1879 or myorg/mygroup)
#   --dir    PATH         Local directory to clone into
#   -a, --archived        Include archived projects (default: exclude)
#   -n, --no-update       Skip pulling changes for already-cloned projects
#   -d, --delete-archived Delete locally cloned projects that are archived on
#                         GitLab (only if no local uncommitted changes)
#   -h, --help            Show this help message
###############################################################################

# ---- Defaults from environment -----------------------------------------------
GITLAB_HOST="${GITLAB_CLONE_HOST:-}"
GROUP_ID="${GITLAB_CLONE_GROUP_ID:-}"
TARGET_DIR="${GITLAB_CLONE_TARGET_DIR:-}"

PER_PAGE=100
MAX_PAGES=50               # safety cap
PARALLEL_JOBS=6            # concurrent clones/pulls

INCLUDE_ARCHIVED=false
UPDATE_EXISTING=true
DELETE_ARCHIVED=false

# ---- Colors (disabled automatically when not a terminal) ---------------------
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_CYAN='\033[0;36m'
    C_MAGENTA='\033[0;35m'
    C_DIM='\033[2m'
else
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_MAGENTA='' C_DIM=''
fi

log_clone()  { printf "${C_GREEN}[clone]${C_RESET}  %s\n"  "$1"; }
log_pull()   { printf "${C_CYAN}[pull]${C_RESET}   %s\n"  "$1"; }
log_skip()   { printf "${C_DIM}[skip]${C_RESET}   %s\n"   "$1"; }
log_keep()   { printf "${C_YELLOW}[keep]${C_RESET}   %s – %s\n" "$1" "$2"; }
log_delete() { printf "${C_MAGENTA}[delete]${C_RESET} %s\n" "$1"; }
log_warn()   { printf "${C_YELLOW}[WARN]${C_RESET}   %s – %s\n" "$1" "$2" >&2; }
log_fail()   { printf "${C_RED}[FAIL]${C_RESET}   %s\n" "$1" >&2; }
log_err()    { printf "${C_RED}[ERROR]${C_RESET}  %s\n" "$1" >&2; }

usage() {
    grep '^#' "$0" | grep -E '^\#( |$)' | sed 's/^# \{0,1\}//' | tail -n +3
    exit 0
}

# ---- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)               GITLAB_HOST="$2";        shift 2 ;;
        --group)              GROUP_ID="$2";            shift 2 ;;
        --dir)                TARGET_DIR="$2";          shift 2 ;;
        -a|--archived)        INCLUDE_ARCHIVED=true;    shift ;;
        -n|--no-update)       UPDATE_EXISTING=false;    shift ;;
        -d|--delete-archived) DELETE_ARCHIVED=true;     shift ;;
        -h|--help)            usage ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
done

# ---- Validate mandatory arguments --------------------------------------------
missing=()
[ -z "$GITLAB_HOST" ] && missing+=("--host / GITLAB_CLONE_HOST")
[ -z "$GROUP_ID"    ] && missing+=("--group / GITLAB_CLONE_GROUP_ID")
[ -z "$TARGET_DIR"  ] && missing+=("--dir / GITLAB_CLONE_TARGET_DIR")

if [ ${#missing[@]} -gt 0 ]; then
    log_err "Missing required configuration:"
    for m in "${missing[@]}"; do
        printf "  ${C_RED}•${C_RESET} %s\n" "$m" >&2
    done
    echo "" >&2
    usage
fi

# ---- Create target directory (with confirmation) -----------------------------
if [ ! -d "$TARGET_DIR" ]; then
    printf "${C_YELLOW}Directory does not exist:${C_RESET} %s\n" "$TARGET_DIR"
    printf "Create it? [y/N] "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            mkdir -p "$TARGET_DIR"
            printf "${C_GREEN}Created:${C_RESET} %s\n" "$TARGET_DIR"
            ;;
        *)
            log_err "Aborted – target directory does not exist."
            exit 1
            ;;
    esac
fi

# ---- Derive the group prefix to strip from paths ----------------------------
# Works for both numeric IDs (need API lookup) and path slugs like "ms" or "org/team"
GROUP_PREFIX=""

raw_group=$(glab api "groups/${GROUP_ID}?simple=true" --hostname "$GITLAB_HOST" 2>/dev/null) || true
GROUP_PREFIX=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read(), strict=False)
    print(data.get('full_path', ''))
except Exception:
    print('')
" <<< "$raw_group")

printf "${C_BOLD}=== Fetching project list from %s group %s ===${C_RESET}\n" "$GITLAB_HOST" "$GROUP_ID"
printf "    prefix=%s  include_archived=%s  update=%s  delete_archived=%s\n" \
    "${GROUP_PREFIX:-<none>}" "$INCLUDE_ARCHIVED" "$UPDATE_EXISTING" "$DELETE_ARCHIVED"

# ---- Temp files & counters ---------------------------------------------------
PROJECT_LIST=$(mktemp)
ARCHIVED_PATHS=$(mktemp)
CNT_DIR=$(mktemp -d)
trap 'rm -f "$PROJECT_LIST" "$ARCHIVED_PATHS"; rm -rf "$CNT_DIR"' EXIT

for f in cloned pulled pull_warn skipped failed deleted kept; do
    echo 0 > "$CNT_DIR/$f"
done

inc() { echo $(( $(cat "$CNT_DIR/$1") + 1 )) > "$CNT_DIR/$1"; }

# Helper: extract rel-path + clone-url from a JSON page
extract_projects() {
    python3 -c "
import json, sys
prefix = sys.argv[1]
data = json.loads(sys.stdin.read(), strict=False)
strip = prefix + '/' if prefix else ''
for p in data:
    full = p.get('path_with_namespace', '')
    url  = p.get('http_url_to_repo', '')
    rel  = full[len(strip):] if strip and full.startswith(strip) else full
    if rel and url:
        print(f'{rel}\t{url}')
" "$GROUP_PREFIX"
}

count_projects() {
    python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read(), strict=False)
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
"
}

# ---- Fetch projects ----------------------------------------------------------
fetch_pages() {
    local archived_param="$1"
    local label="$2"
    local out_file="$3"
    local also_list="${4:-}"   # if non-empty, also append to PROJECT_LIST

    local page=1 total=0
    while [ "$page" -le "$MAX_PAGES" ]; do
        local raw
        raw=$(glab api \
            "groups/${GROUP_ID}/projects?per_page=${PER_PAGE}&page=${page}&archived=${archived_param}&include_subgroups=true&simple=true&order_by=path&sort=asc" \
            --hostname "$GITLAB_HOST" 2>/dev/null) || { log_err "API error ($label) on page $page"; break; }

        local count
        count=$(count_projects <<< "$raw")
        [ "$count" -eq 0 ] && break

        extract_projects <<< "$raw" >> "$out_file"
        [ -n "$also_list" ] && extract_projects <<< "$raw" >> "$also_list"

        total=$((total + count))
        printf "  ${C_DIM}[%s] page %d – %d projects (running total: %d)${C_RESET}\n" \
            "$label" "$page" "$count" "$total"
        page=$((page + 1))
    done
}

fetch_pages "false" "active" "$PROJECT_LIST"

if $INCLUDE_ARCHIVED || $DELETE_ARCHIVED; then
    if $INCLUDE_ARCHIVED; then
        fetch_pages "true" "archived" "$ARCHIVED_PATHS" "$PROJECT_LIST"
    else
        fetch_pages "true" "archived" "$ARCHIVED_PATHS"
    fi
fi

total=$(wc -l < "$PROJECT_LIST" | tr -d ' ')
printf "${C_BOLD}=== Total projects to process: %d ===${C_RESET}\n" "$total"

# ---- Clone / update in parallel ----------------------------------------------
running=0

while IFS=$'\t' read -r rel url; do
    [ -z "$rel" ] && continue
    dest="${TARGET_DIR}/${rel}"

    if [ -d "${dest}/.git" ]; then
        if $UPDATE_EXISTING; then
            while [ "$running" -ge "$PARALLEL_JOBS" ]; do
                wait -n 2>/dev/null || true
                running=$((running - 1))
            done
            (
                if git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
                    log_pull "$rel"
                    echo $(( $(cat "$CNT_DIR/pulled") + 1 )) > "$CNT_DIR/pulled"
                else
                    log_warn "$rel" "could not fast-forward, skipping"
                    echo $(( $(cat "$CNT_DIR/pull_warn") + 1 )) > "$CNT_DIR/pull_warn"
                fi
            ) &
            running=$((running + 1))
        else
            log_skip "$rel"
            inc skipped
        fi
        continue
    fi

    while [ "$running" -ge "$PARALLEL_JOBS" ]; do
        wait -n 2>/dev/null || true
        running=$((running - 1))
    done

    (
        mkdir -p "$(dirname "$dest")"
        if git clone --quiet "$url" "$dest" 2>/dev/null; then
            log_clone "$rel"
            echo $(( $(cat "$CNT_DIR/cloned") + 1 )) > "$CNT_DIR/cloned"
        else
            log_fail "$rel"
            echo $(( $(cat "$CNT_DIR/failed") + 1 )) > "$CNT_DIR/failed"
        fi
    ) &
    running=$((running + 1))

done < "$PROJECT_LIST"

wait

# ---- Delete locally archived projects (if requested) -------------------------
if $DELETE_ARCHIVED && [ -s "$ARCHIVED_PATHS" ]; then
    echo ""
    printf "${C_BOLD}=== Checking archived projects for local deletion ===${C_RESET}\n"

    while IFS=$'\t' read -r rel _url; do
        [ -z "$rel" ] && continue
        dest="${TARGET_DIR}/${rel}"

        [ -d "${dest}/.git" ] || continue

        if git -C "$dest" status --porcelain | grep -q .; then
            log_keep "$rel" "has uncommitted changes"
            inc kept
            continue
        fi
        if ! git -C "$dest" diff --quiet HEAD @{u} 2>/dev/null; then
            log_keep "$rel" "has unpushed commits"
            inc kept
            continue
        fi

        rm -rf "$dest"
        log_delete "$rel"
        inc deleted
    done < "$ARCHIVED_PATHS"
fi

# ---- Summary -----------------------------------------------------------------
n_cloned=$(cat "$CNT_DIR/cloned")
n_pulled=$(cat "$CNT_DIR/pulled")
n_pull_warn=$(cat "$CNT_DIR/pull_warn")
n_skipped=$(cat "$CNT_DIR/skipped")
n_failed=$(cat "$CNT_DIR/failed")
n_deleted=$(cat "$CNT_DIR/deleted")
n_kept=$(cat "$CNT_DIR/kept")
n_dirs=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')

echo ""
printf "${C_BOLD}=== Summary ===${C_RESET}\n"
[ "$n_cloned"    -gt 0 ] && printf "  ${C_GREEN}%-12s${C_RESET} %d\n"   "cloned"      "$n_cloned"
[ "$n_pulled"    -gt 0 ] && printf "  ${C_CYAN}%-12s${C_RESET} %d\n"    "updated"     "$n_pulled"
[ "$n_skipped"   -gt 0 ] && printf "  ${C_DIM}%-12s${C_RESET} %d\n"     "skipped"     "$n_skipped"
[ "$n_deleted"   -gt 0 ] && printf "  ${C_MAGENTA}%-12s${C_RESET} %d\n" "deleted"     "$n_deleted"
[ "$n_kept"      -gt 0 ] && printf "  ${C_YELLOW}%-12s${C_RESET} %d\n"  "kept dirty"  "$n_kept"
[ "$n_pull_warn" -gt 0 ] && printf "  ${C_YELLOW}%-12s${C_RESET} %d\n"  "pull warn"   "$n_pull_warn"
[ "$n_failed"    -gt 0 ] && printf "  ${C_RED}%-12s${C_RESET} %d\n"     "FAILED"      "$n_failed"
printf "  ${C_BOLD}%-12s${C_RESET} %d\n" "total dirs" "$n_dirs"
printf "${C_BOLD}=== Projects are in %s ===${C_RESET}\n" "$TARGET_DIR"
