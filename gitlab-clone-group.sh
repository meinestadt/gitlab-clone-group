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
# preserving namespace structure, and keep existing clones in line with
# GitLab (renamed, moved, archived and removed projects).
# Requires: glab (authenticated), python3, git
#
# Mandatory configuration (flag or environment variable):
#   --host   HOST   GitLab hostname          / GITLAB_CLONE_HOST
#   --group  ID     GitLab group ID or path  / GITLAB_CLONE_GROUP_ID
#   --dir    PATH   Local target directory   / GITLAB_CLONE_TARGET_DIR
#
# Usage: gitlab-clone-group.sh --host HOST --group ID --dir PATH [OPTIONS]
#
# Options:
#   --host   HOST         GitLab hostname (e.g. gitlab.example.com)
#   --group  ID           GitLab group ID or path (e.g. 1879 or myorg/mygroup)
#   --dir    PATH         Local directory to clone into
#   -a, --archived        Include archived projects (default: exclude)
#   -n, --no-update       Skip pulling changes for already-cloned projects
#   -d, --delete-archived Move local clones of projects archived on GitLab to
#                         PATH/.trash (only if nothing is unpushed or stashed)
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

# Never prompt for credentials from a background job; English git messages for first_line
export GIT_TERMINAL_PROMPT=0 LC_MESSAGES=C

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
log_moved()  { printf "${C_CYAN}[moved]${C_RESET}  %s – %s\n" "$1" "$2"; }
log_keep()   { printf "${C_YELLOW}[keep]${C_RESET}   %s – %s\n" "$1" "$2"; }
log_gone()   { printf "${C_YELLOW}[gone]${C_RESET}   %s – %s\n" "$1" "$2"; }
log_delete() { printf "${C_MAGENTA}[trash]${C_RESET}  %s – %s\n" "$1" "$2"; }
log_warn()   { printf "${C_YELLOW}[WARN]${C_RESET}   %s – %s\n" "$1" "$2" >&2; }
log_fail()   { printf "${C_RED}[FAIL]${C_RESET}   %s – %s\n" "$1" "$2" >&2; }
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

if $INCLUDE_ARCHIVED && $DELETE_ARCHIVED; then
    log_err "--archived and --delete-archived contradict each other"
    exit 1
fi

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
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
TRASH_DIR="${TARGET_DIR}/.trash"

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

# Without the prefix, new clones would land one level too deep and moves go unnoticed
if [ -z "$GROUP_PREFIX" ]; then
    log_err "Could not resolve group $GROUP_ID on $GITLAB_HOST"
    exit 1
fi

printf "${C_BOLD}=== Fetching project list from %s group %s ===${C_RESET}\n" "$GITLAB_HOST" "$GROUP_ID"
printf "    prefix=%s  include_archived=%s  update=%s  delete_archived=%s\n" \
    "${GROUP_PREFIX:-<none>}" "$INCLUDE_ARCHIVED" "$UPDATE_EXISTING" "$DELETE_ARCHIVED"

# ---- Temp files & counters ---------------------------------------------------
WORK=$(mktemp -d)
CNT_DIR="$WORK/counts"
mkdir -p "$CNT_DIR"
trap 'rm -rf "$WORK"' EXIT

# One line per event; counted with wc -l, so parallel jobs never lose increments
inc() { echo x >> "$CNT_DIR/$1"; }
count() { if [ -f "$CNT_DIR/$1" ]; then wc -l < "$CNT_DIR/$1" | tr -d ' '; else echo 0; fi; }

# git's error line (or else its first line), for one-line failure reasons
first_line() {
    local text
    text=$(cat)
    { grep -E '^(fatal|error):' <<< "$text" || grep -v '^[[:space:]]*$' <<< "$text"; } | head -1
}

# Helper: extract id, archived flag, rel-path, http and ssh URL from a JSON page
extract_projects() {
    python3 -c "
import json, sys
prefix, archived = sys.argv[1], sys.argv[2]
data = json.loads(sys.stdin.read(), strict=False)
strip = prefix + '/' if prefix else ''
for p in data:
    full = p.get('path_with_namespace', '')
    url  = p.get('http_url_to_repo', '')
    rel  = full[len(strip):] if strip and full.startswith(strip) else full
    if rel and url:
        print('\t'.join([str(p.get('id', '')), archived, rel, url, p.get('ssh_url_to_repo') or '']))
" "$GROUP_PREFIX" "$1"
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
API_LIST="$WORK/api.tsv"
: > "$API_LIST"

fetch_pages() {
    local archived_param="$1"
    local label="$2"

    local page=1 total=0
    while [ "$page" -le "$MAX_PAGES" ]; do
        local raw
        # A partial list would make clones look "gone", so API errors abort the run
        raw=$(glab api \
            "groups/${GROUP_ID}/projects?per_page=${PER_PAGE}&page=${page}&archived=${archived_param}&include_subgroups=true&simple=true&order_by=path&sort=asc" \
            --hostname "$GITLAB_HOST" 2>/dev/null) || { log_err "API error ($label) on page $page"; exit 1; }

        local count
        count=$(count_projects <<< "$raw")
        [ "$count" -eq 0 ] && break

        extract_projects "$archived_param" <<< "$raw" >> "$API_LIST"

        total=$((total + count))
        printf "  ${C_DIM}[%s] page %d – %d projects (running total: %d)${C_RESET}\n" \
            "$label" "$page" "$count" "$total"
        page=$((page + 1))
    done
    if [ "$page" -gt "$MAX_PAGES" ]; then
        log_err "More than $((MAX_PAGES * PER_PAGE)) $label projects – raise MAX_PAGES"
        exit 1
    fi
}

# Archived projects are always fetched so their clones are not reported as gone
fetch_pages "false" "active"
fetch_pages "true" "archived"

if [ ! -s "$API_LIST" ]; then
    log_err "GitLab returned no projects – refusing to reconcile against an empty list"
    exit 1
fi

# ---- Index local clones ------------------------------------------------------
# path <TAB> stored gitlab.projectId <TAB> origin URL
# shortcut: a project literally named node_modules/.venv/vendor/target is not indexed; match by .git content if one appears
LOCAL_INDEX="$WORK/local.tsv"
: > "$LOCAL_INDEX"
while IFS= read -r git_dir; do
    repo="$(dirname "$git_dir")"
    printf '%s\t%s\t%s\n' "$repo" \
        "$(git -C "$repo" config --get gitlab.projectId 2>/dev/null || true)" \
        "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" >> "$LOCAL_INDEX"
done < <(find "$TARGET_DIR" \
    \( -name node_modules -o -name .venv -o -name vendor -o -name target -o -path "$TRASH_DIR" \) -prune \
    -o -name .git -type d -print -prune 2>/dev/null)

# ---- Reconcile GitLab projects with local clones -----------------------------
# Matching uses the stored project ID first, then the normalized origin URL
# (ssh and https forms of the same project match). One action per line:
#   update   <id> <local path> <rel> <url>      known clone
#   moved    <id> <local path> <rel> <new url>  known clone, GitLab path changed
#   clone    <id> <dest path>  <rel> <url>      not cloned yet
#   archived <id> <local path> <rel>            clone of an archived project
#   dup      <id> <local path> <rel>            second clone of the same project
#   gone     -    <local path> <origin>         clone whose project left the group
#   skiparch <id> -            <rel>            archived, not cloned, not requested
PLAN="$WORK/plan.tsv"
python3 - "$API_LIST" "$LOCAL_INDEX" "$TARGET_DIR" "$GITLAB_HOST" "$GROUP_PREFIX" "$INCLUDE_ARCHIVED" > "$PLAN" <<'PY'
import json, os, re, subprocess, sys, urllib.parse

api_file, local_file, target, host, prefix, include_archived = sys.argv[1:7]

def norm(url):
    """host/path, lowercased, without scheme, user, port and .git."""
    u = url.strip()
    m = re.match(r'^[a-z][a-z0-9+.-]*://(?:[^@/]*@)?([^/:]*)(?::\d+)?/(.*)$', u, re.I)
    if not m:
        m = re.match(r'^(?:[^@/]+@)?([^:/]+):(.*)$', u)
    if not m:
        return u.rstrip('/').lower()
    h, path = m.groups()
    path = path.strip('/')
    if path.endswith('.git'):
        path = path[:-4]
    return (h + '/' + path).lower()

assert norm('git@git.example.com:ms/ai/x.git') == norm('https://git.example.com/ms/ai/x.git') == 'git.example.com/ms/ai/x'
assert norm('ssh://git@Git.Example.com:2222/ms/x.git') == norm('https://oauth2:t@git.example.com/ms/x/') == 'git.example.com/ms/x'

def is_ssh(url):
    return not re.match(r'^(https?|file)://', url, re.I)

local = []
for line in open(local_file):
    path, pid, origin = line.rstrip('\n').split('\t')
    local.append({'path': path, 'id': pid, 'origin': origin, 'key': norm(origin) if origin else ''})

api = [line.rstrip('\n').split('\t') for line in open(api_file)]
api_keys = {norm(u) for row in api for u in row[3:5] if u}
group_key = norm('https://%s/%s' % (host, prefix)) + '/' if prefix else None

# Clones without an ID whose URL is unknown may predate a rename/move:
# GitLab's API still resolves the old path to the project.
for l in local:
    if l['id'] or not group_key or not l['key'].startswith(group_key) or l['key'] in api_keys:
        continue
    old_path = l['key'].split('/', 1)[1]
    res = subprocess.run(['glab', 'api', 'projects/' + urllib.parse.quote(old_path, safe=''),
                          '--hostname', host], capture_output=True, text=True)
    try:
        l['id'] = str(json.loads(res.stdout)['id']) if res.returncode == 0 else ''
    except (ValueError, KeyError, TypeError):
        pass

by_id, by_url = {}, {}
for l in local:
    if l['id']:
        by_id.setdefault(l['id'], []).append(l)
    if l['key']:
        by_url.setdefault(l['key'], []).append(l)

out = []
used = set()
for pid, archived, rel, http, ssh in api:
    archived = archived == 'true'
    keys = {norm(http)} | ({norm(ssh)} if ssh else set())
    expected = os.path.join(target, rel)
    cands = by_id.get(pid, []) + [c for k in keys for c in by_url.get(k, []) if not c['id']]
    seen = set()
    cands = [c for c in cands if c['path'] not in used and not (c['path'] in seen or seen.add(c['path']))]
    if not cands:
        if archived and include_archived != 'true':
            out.append(['skiparch', pid, '-', rel])
        else:
            out.append(['clone', pid, expected, rel, http])
        continue
    # Prefer the clone at the expected path, report any others as duplicates
    cands.sort(key=lambda c: c['path'] != expected)
    main, dups = cands[0], cands[1:]
    used.update(c['path'] for c in cands)
    for d in dups:
        out.append(['dup', pid, d['path'], rel])
    if archived:
        out.append(['archived', pid, main['path'], rel])
        if include_archived != 'true':
            continue
    # Only an origin at an old path inside this group is a move; a missing origin
    # or one pointing elsewhere (fork, mirror) is the user's choice and kept
    if main['key'] in keys or not main['key'].startswith(group_key):
        out.append(['update', pid, main['path'], rel, http])
    else:
        # Keep the protocol the user chose for this clone
        new = ssh if ssh and main['origin'] and is_ssh(main['origin']) else http
        out.append(['moved', pid, main['path'], rel, new])

# Clones nobody claimed: report those that belonged to this group
for l in local:
    if l['path'] in used:
        continue
    if l['id'] or (group_key and l['key'].startswith(group_key)):
        out.append(['gone', '-', l['path'], l['origin'] or '<no origin>'])

for row in out:
    print('\t'.join(row))
PY

relpath() { echo "${1#"$TARGET_DIR"/}"; }

total=$(grep -c -E '^(update|moved|clone)' "$PLAN" || true)
printf "${C_BOLD}=== Total projects to process: %d ===${C_RESET}\n" "$total"

# ---- Record project IDs and follow moves (sequential, local only) ------------
while IFS=$'\t' read -r action pid path rel url; do
    case "$action" in
        update|moved|archived)
            git -C "$path" config gitlab.projectId "$pid"
            ;;
    esac
    if [ "$action" = moved ]; then
        git -C "$path" remote set-url origin "$url"
        if [ "$(relpath "$path")" = "$rel" ]; then
            log_moved "$rel" "origin updated to $url"
        else
            log_moved "$(relpath "$path")" "now $rel on GitLab; origin updated, folder left in place"
        fi
        inc moved
    fi
done < "$PLAN"

# ---- Clone / update in parallel ----------------------------------------------
# jobs-based throttle instead of `wait -n`, which macOS's bash 3.2 lacks
throttle() {
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL_JOBS" ]; do
        sleep 0.2
    done
}

while IFS=$'\t' read -r action pid path rel url; do
    case "$action" in
        update|moved)
            if ! $UPDATE_EXISTING; then
                log_skip "$(relpath "$path")"
                inc skipped
                continue
            fi
            throttle
            (
                if out=$(git -C "$path" pull --ff-only --quiet 2>&1); then
                    log_pull "$(relpath "$path")"
                    inc pulled
                else
                    log_warn "$(relpath "$path")" "$(first_line <<< "$out")"
                    inc pull_warn
                fi
            ) &
            ;;
        clone)
            if [ -e "$path" ]; then
                log_fail "$rel" "$path already exists and is not a clone of this project"
                inc failed
                continue
            fi
            throttle
            (
                mkdir -p "$(dirname "$path")"
                if out=$(git clone --quiet "$url" "$path" 2>&1); then
                    git -C "$path" config gitlab.projectId "$pid"
                    log_clone "$rel"
                    inc cloned
                else
                    log_fail "$rel" "$(first_line <<< "$out")"
                    inc failed
                fi
            ) &
            ;;
    esac
done < "$PLAN"

wait

# ---- Report clones that no longer match a project ----------------------------
while IFS=$'\t' read -r action pid path rel url; do
    case "$action" in
        dup)
            log_keep "$(relpath "$path")" "another clone of $rel (project $pid), not updated"
            inc dup
            ;;
        gone)
            # The 4th column holds the origin URL here
            log_gone "$(relpath "$path")" "not in the group any more (moved out or deleted), origin $rel"
            inc gone
            ;;
    esac
done < "$PLAN"

# ---- Move clones of archived projects to the trash (if requested) ------------
# Prints a reason when the clone holds work that exists nowhere else.
# Fails closed: any git error counts as unsafe.
unsafe_reason() {
    local repo="$1" out
    out=$(git -C "$repo" status --porcelain 2>/dev/null) || { echo "git status failed"; return; }
    [ -n "$out" ] && { echo "has uncommitted or untracked changes"; return; }
    out=$(git -C "$repo" stash list 2>/dev/null) || { echo "git stash list failed"; return; }
    [ -n "$out" ] && { echo "has stashed changes"; return; }
    # HEAD covers commits made on a detached HEAD
    out=$(git -C "$repo" log --branches HEAD --not --remotes --oneline 2>/dev/null) || { echo "git log failed"; return; }
    [ -n "$out" ] && { echo "has commits not pushed to any remote"; return; }
    out=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || { echo "git worktree list failed"; return; }
    [ "$(grep -c '^worktree ' <<< "$out")" -gt 1 ] && { echo "has linked worktrees"; return; }
    return 0
}

if $DELETE_ARCHIVED; then
    stamp=$(date +%Y%m%d-%H%M%S)
    while IFS=$'\t' read -r action pid path rel url; do
        [ "$action" = archived ] || continue
        reason=$(unsafe_reason "$path")
        if [ -n "$reason" ]; then
            log_keep "$(relpath "$path")" "$reason"
            inc kept
            continue
        fi
        # Moved, not deleted: gitignored files such as .env survive in the trash
        dest="${TRASH_DIR}/$(relpath "$path").${stamp}"
        mkdir -p "$(dirname "$dest")"
        mv "$path" "$dest"
        log_delete "$(relpath "$path")" "moved to $dest"
        inc deleted
    done < "$PLAN"
fi

# ---- Summary -----------------------------------------------------------------
n_dirs=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .trash | wc -l | tr -d ' ')
n_archived=$(grep -c '^archived' "$PLAN" || true)

summary_line() {
    [ "$3" -gt 0 ] && printf "  ${1}%-12s${C_RESET} %d\n" "$2" "$3"
    return 0
}

echo ""
printf "${C_BOLD}=== Summary ===${C_RESET}\n"
summary_line "$C_GREEN"   "cloned"     "$(count cloned)"
summary_line "$C_CYAN"    "updated"    "$(count pulled)"
summary_line "$C_CYAN"    "moved"      "$(count moved)"
summary_line "$C_DIM"     "skipped"    "$(count skipped)"
summary_line "$C_DIM"     "archived"   "$n_archived"
summary_line "$C_MAGENTA" "trashed"    "$(count deleted)"
summary_line "$C_YELLOW"  "kept dirty" "$(count kept)"
summary_line "$C_YELLOW"  "duplicate"  "$(count dup)"
summary_line "$C_YELLOW"  "gone"       "$(count gone)"
summary_line "$C_YELLOW"  "pull warn"  "$(count pull_warn)"
summary_line "$C_RED"     "FAILED"     "$(count failed)"
printf "  ${C_BOLD}%-12s${C_RESET} %d\n" "total dirs" "$n_dirs"
printf "${C_BOLD}=== Projects are in %s ===${C_RESET}\n" "$TARGET_DIR"
