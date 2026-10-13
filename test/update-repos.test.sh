#!/usr/bin/env bash
# Offline test for update-repos.sh using local bare repos. Usage: test/update-repos.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/update-repos.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
W="$T/work"
mkdir -p "$W"

export GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.email t@example.com
git config --global user.name test
git config --global init.defaultBranch main

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# Bare remote with branches main, feature, wt, div
mkremote() {
    git init -q --bare "$T/$1.git"
    git clone -q "$T/$1.git" "$T/seed-$1" 2>/dev/null
    printf 'a\n' > "$T/seed-$1/file"
    git -C "$T/seed-$1" add -A && git -C "$T/seed-$1" commit -qm init
    git -C "$T/seed-$1" push -q origin main main:feature main:wt main:div
}
# New upstream commit on <remote> <branch> changing <file>
advance() {
    git -C "$T/seed-$1" fetch -q && git -C "$T/seed-$1" checkout -q -B "$2" "origin/$2"
    echo "$2-v2" >> "$T/seed-$1/$3" && git -C "$T/seed-$1" add -A && git -C "$T/seed-$1" commit -qm v2
    git -C "$T/seed-$1" push -q origin "$2"
}
sha() { git -C "$1" rev-parse "$2"; }

# r1: behind on every branch, local dirty + untracked work that upstream does not touch
mkremote r1
git clone -q "$T/r1.git" "$W/r1"
for b in feature wt div; do git -C "$W/r1" branch -q --track "$b" "origin/$b"; done
git -C "$W/r1" worktree add -q "$T/r1-wt" wt
git -C "$W/r1" switch -q div && git -C "$W/r1" commit -qm local --allow-empty && git -C "$W/r1" switch -q main
echo local >> "$W/r1/file"; echo scratch > "$W/r1/notes.txt"
for b in main feature wt div; do advance r1 "$b" "up-$b"; done
wt_before=$(sha "$W/r1" wt); div_before=$(sha "$W/r1" div)

# r2: dirty file that the upstream change would overwrite
mkremote r2
git clone -q "$T/r2.git" "$W/r2"
echo mine >> "$W/r2/file"
advance r2 main file

# r3: second remote with a new branch; r4: branch without upstream; r5: no remote
mkremote r3; mkremote r3up
git clone -q "$T/r3.git" "$W/r3" && git -C "$W/r3" remote add upstream "$T/r3up.git"
advance r3up main extra
git clone -q "$T/r1.git" "$W/r4" && git -C "$W/r4" switch -qc topic
git init -q "$W/r5"
# Path longer than 255 bytes (macOS xargs -I limit)
long="$W/$(printf 'l%.0s' $(seq 1 120))/$(printf 'm%.0s' $(seq 1 120))"
mkdir -p "$long" && git clone -q "$T/r1.git" "$long/r6"
# Repo inside node_modules must be ignored
git init -q "$W/r1/node_modules/dep"

out=$("$SCRIPT" "$W" 2>&1) || { echo "$out"; exit 1; }
echo "$out" | sed 's/^/    /'

check "only real repos found"                 'echo "$out" | grep -q "Found 6 repositories"'
check "current branch fast-forwarded"         '[ -f "$W/r1/up-main" ]'
check "dirty change kept"                     'grep -q local "$W/r1/file"'
check "untracked file kept"                   '[ -f "$W/r1/notes.txt" ]'
check "other branch fast-forwarded"           '[ "$(sha "$W/r1" feature)" = "$(sha "$W/r1" origin/feature)" ]'
check "worktree branch left alone"            '[ "$(sha "$W/r1" wt)" = "$wt_before" ]'
check "diverged branch left alone"            '[ "$(sha "$W/r1" div)" = "$div_before" ]'
check "conflicting dirty repo fails"          'echo "$out" | grep -q "FAIL r2"'
check "conflicting dirty file intact"         'grep -q mine "$W/r2/file"'
check "failure reason shown"                  'echo "$out" | grep -q "would be overwritten"'
check "all remotes fetched"                   'git -C "$W/r3" rev-parse -q --verify upstream/main >/dev/null'
check "no upstream is a skip"                 'echo "$out" | grep -q "SKIP r4 (topic has no upstream"'
check "long path updated"                     'echo "$out" | grep -q "OK   .*r6"'
check "no remote is a skip"                   'echo "$out" | grep -q "SKIP r5 (no remote)"'

echo
[ "$fails" -eq 0 ] && echo "All tests passed" || { echo "$fails test(s) failed"; exit 1; }
