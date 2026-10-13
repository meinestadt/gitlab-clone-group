# gitlab-clone-group

English | [Deutsch](README.de.md)

Two Bash scripts that keep local git repositories in sync with their remotes without touching local work:

- **`gitlab-clone-group.sh`** clones all projects from a GitLab group into a local directory, preserving the full namespace structure, and keeps existing clones in line with GitLab (renamed, moved, archived and removed projects). Designed for teams that need a reliable, repeatable way to mirror or synchronize an entire GitLab group — including subgroups — to a local machine.
- **`update-repos.sh`** updates every git repository under a directory, from any host (GitLab, GitHub, others): it fetches all remotes and fast-forwards local branches.

Use them together for a full sync: the first finds and clones new projects, the second updates everything (see [Full sync](#full-sync)).

## Features

- Clones all active projects from a GitLab group and its subgroups
- Preserves the namespace hierarchy as a local directory tree
- Updates already-cloned repositories via `git pull --ff-only` by default
- Recognises existing clones by GitLab project ID or remote URL (ssh and https), whatever their local path
- Follows renamed and moved projects: updates `origin` and reports the move instead of cloning twice
- Reports duplicate clones and clones whose project left the group
- Parallel execution (6 concurrent jobs by default) for fast operation on large groups
- Optional inclusion of archived projects
- Safe cleanup of locally cloned projects that have been archived on GitLab
  (moved to a `.trash` folder, and only if nothing is uncommitted, stashed or unpushed)
- Color-coded output for at-a-glance status (automatically disabled in non-TTY environments)
- Summary report at the end of every run
- Configuration via CLI flags or environment variables

## Requirements

| Tool | Purpose |
|------|---------|
| [`glab`](https://gitlab.com/gitlab-org/cli) | GitLab CLI, must be authenticated |
| `git` | Cloning and pulling repositories |
| `python3` | JSON parsing of GitLab API responses |
| `bash` 3.2+ | Script runtime (macOS system bash works) |

### Installing glab

```bash
# macOS
brew install glab

# Linux (Homebrew)
brew install glab

# Other platforms: https://gitlab.com/gitlab-org/cli#installation
```

After installation, authenticate against your GitLab instance:

```bash
glab auth login --hostname git.example.com
```

## Installation

```bash
# Clone this repository
git clone https://github.com/meinestadt/gitlab-clone-group.git

# Make the scripts executable
chmod +x gitlab-clone-group/gitlab-clone-group.sh gitlab-clone-group/update-repos.sh

# Optionally install globally
cp gitlab-clone-group/gitlab-clone-group.sh /usr/local/bin/gitlab-clone-group
cp gitlab-clone-group/update-repos.sh /usr/local/bin/update-repos
```

## Usage

```
gitlab-clone-group.sh --host HOST --group ID --dir PATH [OPTIONS]
```

### Mandatory parameters

All three mandatory parameters can be passed as CLI flags or set via environment variables. CLI flags always take precedence.

| Flag | Environment variable | Description |
|------|---------------------|-------------|
| `--host HOST` | `GITLAB_CLONE_HOST` | GitLab hostname (e.g. `gitlab.example.com`) |
| `--group ID` | `GITLAB_CLONE_GROUP_ID` | Group numeric ID or full path (e.g. `1879` or `myorg/myteam`) |
| `--dir PATH` | `GITLAB_CLONE_TARGET_DIR` | Local directory to clone into |

If the target directory does not exist, the script will prompt before creating it.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-a`, `--archived` | off | Also clone archived projects |
| `-n`, `--no-update` | off | Skip `git pull` on already-cloned repositories (only counted in the summary, not listed) |
| `-d`, `--delete-archived` | off | Move local copies of projects archived on GitLab to `PATH/.trash` (only if clean, see below). Cannot be combined with `-a` |
| `-h`, `--help` | | Show usage information |

## Examples

### Initial clone of a group

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup
```

### Daily sync via environment variables

```bash
export GITLAB_CLONE_HOST=git.example.com
export GITLAB_CLONE_GROUP_ID=1879
export GITLAB_CLONE_TARGET_DIR=~/Projects/mygroup

gitlab-clone-group.sh
```

### Clone everything including archived projects

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group myorg/myteam \
  --dir ~/Projects/myteam \
  --archived
```

### Sync and remove locally archived projects

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup \
  --delete-archived
```

### Clone only, skip updates to existing repositories

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup \
  --no-update
```

### Cron job (daily sync at 06:00)

```cron
0 6 * * * GITLAB_CLONE_HOST=git.example.com GITLAB_CLONE_GROUP_ID=1879 GITLAB_CLONE_TARGET_DIR=/srv/mirror /usr/local/bin/gitlab-clone-group >> /var/log/gitlab-clone-group.log 2>&1
```

## Updating all repositories (`update-repos.sh`)

```
update-repos.sh [DIRECTORY] [MAX_PARALLEL]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `DIRECTORY` | current directory | Searched recursively for git repositories |
| `MAX_PARALLEL` | `8` | Maximum concurrent repositories |

`update-repos.sh` needs only `git` and works on every repository it finds, wherever it was cloned from. Folders named `node_modules`, `.venv`, `vendor`, `target` and `.trash` are skipped while searching. For each repository it:

1. Runs `git fetch --all --prune`, which updates the remote-tracking branches of every remote and never touches the working tree.
2. Fast-forwards every other local branch that is strictly behind its upstream. Diverged branches and branches checked out in another worktree are left alone.
3. Fast-forwards the checked-out branch with `git merge --ff-only @{u}`. Git refuses if a change would overwrite uncommitted or untracked files, or if the branch has diverged.

| Status | Meaning |
|--------|---------|
| `OK` | Fetched and fast-forwarded (or already up to date); `+N other branch(es)` counts extra branches moved |
| `SKIP` | No remote, detached HEAD, or the current branch has no upstream (other branches are still fetched and fast-forwarded) |
| `FAIL` | Fetch or fast-forward failed; git's reason is listed in the summary |

Nothing is ever merged, rebased, reset or deleted, so local commits, uncommitted changes and untracked files stay as they are.

## Full sync

Let `gitlab-clone-group.sh` find and clone new projects (and follow moved ones), then let `update-repos.sh` update everything, including repositories from other hosts:

```bash
gitlab-clone-group.sh --host git.example.com --group mygroup --dir ~/Projects/mygroup --no-update \
  && update-repos.sh ~/Projects
```

## Output

The script uses color-coded log lines (suppressed automatically when piped or redirected):

| Tag | Color | Meaning |
|-----|-------|---------|
| `[clone]` | Green | Repository newly cloned |
| `[pull]` | Cyan | Existing repository successfully updated |
| `[moved]` | Cyan | Project renamed or moved on GitLab — `origin` updated, folder left in place |
| `[keep]` | Yellow | Archived project not moved to trash (has local work), or a duplicate clone |
| `[gone]` | Yellow | Local clone whose project is no longer in the group (moved out or deleted) |
| `[trash]` | Magenta | Local copy of archived project moved to `.trash` |
| `[WARN]` | Yellow | `git pull --ff-only` failed — git's reason is shown |
| `[FAIL]` | Red | `git clone` failed — git's reason is shown |
| `[ERROR]` | Red | API or configuration error |

### Example output

```
=== Fetching project list from git.example.com group 1879 ===
    prefix=myorg  include_archived=false  update=true  delete_archived=false
  [active] page 1 – 100 projects (running total: 100)
  [active] page 2 – 47 projects (running total: 147)
=== Total projects to process: 147 ===
[clone]  service-a
[clone]  service-b
[pull]   shared/utils
[pull]   shared/config
[WARN]   legacy/old-api – fatal: Not possible to fast-forward, aborting.

=== Summary ===
  cloned       2
  updated      144
  pull warn    1
  total dirs   147
=== Projects are in /home/user/Projects/mygroup ===
```

## How it works

### Directory structure

The script mirrors the GitLab namespace hierarchy locally. For a group `myorg` with path `myorg/team-a/service-x`, the local layout will be:

```
~/Projects/mygroup/
└── team-a/
    └── service-x/
```

The top-level group prefix (`myorg/`) is stripped automatically — the script resolves it via the GitLab Groups API, so it works with both numeric group IDs and path slugs.

### Matching local clones to GitLab projects

Before cloning anything, the script indexes every git repository under the target directory and matches it to the project list:

1. By the GitLab project ID stored in the clone's config (`git config gitlab.projectId`). The script writes this ID on every clone and on every existing clone it recognises, so later renames and moves are followed reliably.
2. Otherwise by the normalized `origin` URL. `git@host:group/x.git` and `https://host/group/x.git` count as the same project, so clones in a different folder layout or with a different protocol are not cloned again.
3. For a clone inside the group whose URL matches no project, the script asks the GitLab API for the old path once. GitLab resolves renamed and moved projects to their new location, so moves that happened before ID tracking are caught too.

A matched clone whose `origin` still points to an old path inside the group gets `origin` updated (keeping ssh or https as it was) and is reported as `[moved]`. The folder stays where it is, so IDE projects and open terminals keep working. A second clone of the same project is reported as a duplicate and not updated. A clone whose project is no longer in the group is reported as `[gone]` and left untouched.

A clone whose `origin` points elsewhere (a fork or mirror) or that has no `origin` keeps its remotes untouched.

If the group cannot be resolved, the API returns no projects, or the listing hits the `MAX_PAGES` cap, the script aborts instead of cloning into the wrong folders or reporting clones as gone.

### Parallel execution

Clones and pulls are dispatched as background jobs with a concurrency limit of 6 (controlled by `PARALLEL_JOBS` inside the script). The main loop waits for a free slot before starting the next job.

### Update strategy

Existing repositories are updated with `git pull --ff-only --quiet`. This only advances non-diverged branches and never overwrites local changes. If a fast-forward is not possible (e.g. diverged local commits, or uncommitted changes in files the update touches), a `[WARN]` with git's reason is emitted and the repository is left unchanged — no force-reset, no data loss.

### Safe deletion of archived projects

When `--delete-archived` is used, each local clone of an archived project is checked for work that exists nowhere else:

1. Uncommitted changes or untracked files (`git status --porcelain`)
2. Stashed changes (`git stash list`)
3. Commits on any local branch or a detached HEAD that are not on any remote (`git log --branches HEAD --not --remotes`)
4. Linked worktrees (`git worktree list`), which moving the clone would break

If any of these git commands fails, the clone counts as unsafe. Clones that pass all four checks are moved to `PATH/.trash/<path>.<timestamp>`, never deleted, so gitignored files such as `.env` survive. Empty the trash yourself when you no longer need it. All other clones are logged as `[keep]` with the specific reason.

### Counter tracking across subshells

Because `git clone` and `git pull` run in background subshells (`&`), standard shell variables cannot be shared back to the parent. Each event appends one line to a counter file in a temporary directory (`mktemp -d`); the summary counts the lines, so parallel jobs never lose an increment. The temp directory is cleaned up on exit via `trap`.

### API pagination

The GitLab Projects API is paginated at 100 results per page. The script iterates pages until an empty response is received, up to a safety cap of 50 pages (5,000 projects). Both active and archived project lists are always fetched, so clones of archived projects are not mistaken for gone ones.

## Configuration reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `GITLAB_CLONE_HOST` | env / `--host` | — | GitLab hostname (mandatory) |
| `GITLAB_CLONE_GROUP_ID` | env / `--group` | — | GitLab group ID or path (mandatory) |
| `GITLAB_CLONE_TARGET_DIR` | env / `--dir` | — | Local clone target (mandatory) |
| `PER_PAGE` | script constant | `100` | API results per page |
| `MAX_PAGES` | script constant | `50` | Maximum pages to fetch (safety cap) |
| `PARALLEL_JOBS` | script constant | `6` | Maximum concurrent clone/pull jobs |

`PER_PAGE`, `MAX_PAGES`, and `PARALLEL_JOBS` can be adjusted by editing the constants near the top of the script.

## Testing

Both test suites run offline against local bare repositories:

- `test/run-tests.sh` tests `gitlab-clone-group.sh` with a fake `glab`: cloning, matching, moves, gone and duplicate clones, and the archive safety checks.
- `test/update-repos.test.sh` tests `update-repos.sh`: fast-forwarding, kept local changes, worktree and diverged branches, multiple remotes and skip reasons.

```bash
test/run-tests.sh
test/update-repos.test.sh
```

## License

MIT License — Copyright (c) 2026 meinestadt.de GmbH, Author: Robert Wachtel.
See the license header inside `gitlab-clone-group.sh` for the full license text.
