#!/usr/bin/env bash
# Offline test for gitlab-clone-group.sh: a fake `glab` serves fixture JSON,
# local bare repos stand in for GitLab. Usage: test/run-tests.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gitlab-clone-group.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
R="$T/remote"          # bare "GitLab" repos
W="$T/work"            # target dir
mkdir -p "$R" "$W" "$T/bin"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_SSH_COMMAND=false
git config --global user.email t@example.com
git config --global user.name test
git config --global init.defaultBranch main

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# Bare remote ms/<path> with one commit
mkremote() {
    git init -q --bare "$R/ms/$1.git"
    local tmp="$T/seed-$RANDOM"
    git clone -q "$R/ms/$1.git" "$tmp" 2>/dev/null
    echo "$1" > "$tmp/README" && printf '.env\n' > "$tmp/.gitignore"
    git -C "$tmp" add -A && git -C "$tmp" commit -qm init && git -C "$tmp" push -q origin HEAD:main
    rm -rf "$tmp"
}
url() { echo "file://$R/ms/$1.git"; }

# Fake glab: projects-<archived>.json for page 1, [] afterwards
cat > "$T/bin/glab" <<EOF
#!/usr/bin/env bash
ep="\$2"
case "\$ep" in
    groups/ms\?*) echo '{"full_path":"ms"}' ;;
    projects/ms%2Fold) echo '{"id":9,"path_with_namespace":"ms/new9"}' ;;
    projects/*) exit 1 ;;
    *page=1\&archived=true*)  cat "$T/projects-true.json" ;;
    *page=1\&archived=false*) cat "$T/projects-false.json" ;;
    *) echo '[]' ;;
esac
EOF
chmod +x "$T/bin/glab"
export PATH="$T/bin:$PATH"

project() {  # id path
    printf '{"id":%s,"path_with_namespace":"ms/%s","http_url_to_repo":"%s","ssh_url_to_repo":"git@fake:ms/%s.git"}' \
        "$1" "$2" "$(url "$2")" "$2"
}

for p in a b c d sub/d2 e f g h i j; do mkremote "$p"; done

# --- Local state before the run ----------------------------------------------
git clone -q "$(url b)" "$W/b"                                   # https-style clone, no ID yet
echo scratch > "$W/b/notes.txt"                                  # untracked, must survive pull
git clone -q "$(url c)" "$W/flat/c-local"                        # other layout, ssh remote
git -C "$W/flat/c-local" remote set-url origin git@fake:ms/c.git
git clone -q "$(url d)" "$W/d" && git -C "$W/d" config gitlab.projectId 4   # will move to sub/d2
git -C "$W/d" remote set-url origin git@fake:ms/d.git
git clone -q "$(url a)" "$W/fork" && git -C "$W/fork" config gitlab.projectId 10    # origin is a fork
git clone -q "$(url a)" "$W/norigin" && git -C "$W/norigin" config gitlab.projectId 11 \
    && git -C "$W/norigin" remote rename origin gitlab                                 # no origin remote
git clone -q "$(url e)" "$W/e" && git -C "$W/e" config gitlab.projectId 5   # leaves the group
git clone -q "$(url a)" "$W/old" && git -C "$W/old" remote set-url origin git@fake:ms/old.git  # moved before ID tracking
for p in f g h; do git clone -q "$(url "$p")" "$W/$p"; done
echo SECRET=1 > "$W/f/.env"                                      # ignored file in a clean repo
echo wip >> "$W/g/README" && git -C "$W/g" stash -q              # stash only
git -C "$W/h" switch -qc local-only && git -C "$W/h" commit -qm x --allow-empty   # unpushed branch
for p in i j; do git clone -q "$(url "$p")" "$W/$p"; done
git -C "$W/i" checkout -q --detach && git -C "$W/i" commit -qm detached --allow-empty   # detached commit
git -C "$W/j" worktree add -q "$T/j-wt" -b side                                        # linked worktree

# New upstream commit for b
tmp="$T/up"; git clone -q "$(url b)" "$tmp"
echo v2 >> "$tmp/README" && git -C "$tmp" commit -qam v2 && git -C "$tmp" push -q

# --- GitLab state -------------------------------------------------------------
echo "[$(project 1 a),$(project 2 b),$(project 3 c),$(project 4 sub/d2),$(project 9 new9),$(project 10 fork9),$(project 11 norigin9)]" > "$T/projects-false.json"
echo "[$(project 6 f),$(project 7 g),$(project 8 h),$(project 12 i),$(project 13 j)]" > "$T/projects-true.json"

out=$("$SCRIPT" --host fake --group ms --dir "$W" -d 2>&1) || { echo "$out"; exit 1; }
echo "$out" | sed 's/^/    /'

check "new project cloned"               '[ -f "$W/a/README" ]'
check "clone records project ID"         '[ "$(git -C "$W/a" config gitlab.projectId)" = 1 ]'
check "existing clone gets project ID"   '[ "$(git -C "$W/b" config gitlab.projectId)" = 2 ]'
check "existing clone pulled"            'grep -q v2 "$W/b/README"'
check "untracked file kept on pull"      '[ -f "$W/b/notes.txt" ]'
check "ssh clone in other layout matched, not re-cloned" '[ ! -e "$W/c" ] && [ "$(git -C "$W/flat/c-local" config gitlab.projectId)" = 3 ]'
check "ssh clone failing pull is a warning" 'echo "$out" | grep -q "WARN.*flat/c-local"'
check "moved project: origin updated"    '[ "$(git -C "$W/d" remote get-url origin)" = git@fake:ms/sub/d2.git ]'
check "fork origin left alone"           '[ "$(git -C "$W/fork" remote get-url origin)" = "$(url a)" ] && [ ! -e "$W/fork9" ]'
check "clone without origin does not abort" '[ ! -e "$W/norigin9" ] && echo "$out" | grep -q "Summary"'
check "moved project: not cloned twice"  '[ ! -e "$W/sub/d2" ]'
check "moved project reported"           'echo "$out" | grep -q "moved.*d – now sub/d2"'
check "move before ID tracking: old path resolved" '[ "$(git -C "$W/old" config gitlab.projectId)" = 9 ] && [ ! -e "$W/new9" ]'
check "move before ID tracking: ssh origin kept"   '[ "$(git -C "$W/old" remote get-url origin)" = git@fake:ms/new9.git ]'
check "project that left group reported" 'echo "$out" | grep -q "gone.*e"'
check "gone clone kept on disk"          '[ -d "$W/e/.git" ]'
check "clean archived clone trashed"     '[ ! -e "$W/f" ] && ls "$W"/.trash/f.*/.env >/dev/null'
check "archived clone with stash kept"   '[ -d "$W/g/.git" ] && echo "$out" | grep -q "g – has stashed changes"'
check "archived clone with detached commit kept" '[ -d "$W/i/.git" ] && echo "$out" | grep -q "i – has commits not pushed"'
check "archived clone with worktree kept"  '[ -d "$W/j/.git" ] && echo "$out" | grep -q "j – has linked worktrees"'
check "archived clone with unpushed branch kept" '[ -d "$W/h/.git" ] && echo "$out" | grep -q "h – has commits not pushed"'

# Second run: nothing new to clone, nothing reported twice
out2=$("$SCRIPT" --host fake --group ms --dir "$W" -n 2>&1)
check "second run clones nothing"        '! echo "$out2" | grep -q "\[clone\]"'
check "second run sees no move"          '! echo "$out2" | grep -q "\[moved\]"'

# Unresolvable group must abort, not clone into the wrong folders
check "unknown group aborts"             '! "$SCRIPT" --host fake --group nope --dir "$W" -n >/dev/null 2>&1'

# Empty API answer must not mark everything as gone
echo '[]' > "$T/projects-false.json"; echo '[]' > "$T/projects-true.json"
check "empty project list aborts"        '! "$SCRIPT" --host fake --group ms --dir "$W" -n >/dev/null 2>&1'

echo
[ "$fails" -eq 0 ] && echo "All tests passed" || { echo "$fails test(s) failed"; exit 1; }
