# gitlab-clone-group

A Bash script that clones all projects from a GitLab group into a local directory, preserving the full namespace structure. Designed for teams that need a reliable, repeatable way to mirror or synchronize an entire GitLab group — including subgroups — to a local machine.

## Features

- Clones all active projects from a GitLab group and its subgroups
- Preserves the namespace hierarchy as a local directory tree
- Updates already-cloned repositories via `git pull --ff-only` by default
- Parallel execution (6 concurrent jobs by default) for fast operation on large groups
- Optional inclusion of archived projects
- Safe cleanup of locally cloned projects that have been archived on GitLab
  (only deletes if there are no uncommitted changes or unpushed commits)
- Color-coded output for at-a-glance status (automatically disabled in non-TTY environments)
- Summary report at the end of every run
- Configuration via CLI flags or environment variables

## Requirements

| Tool | Purpose |
|------|---------|
| [`glab`](https://gitlab.com/gitlab-org/cli) | GitLab CLI, must be authenticated |
| `git` | Cloning and pulling repositories |
| `python3` | JSON parsing of GitLab API responses |
| `bash` 4.0+ | Script runtime |

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

# Make the script executable
chmod +x gitlab-clone-group/gitlab-clone-group.sh

# Optionally install globally
cp gitlab-clone-group/gitlab-clone-group.sh /usr/local/bin/gitlab-clone-group
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
| `-n`, `--no-update` | off | Skip `git pull` on already-cloned repositories |
| `-d`, `--delete-archived` | off | Delete local copies of projects archived on GitLab (safe — only if clean) |
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

## Output

The script uses color-coded log lines (suppressed automatically when piped or redirected):

| Tag | Color | Meaning |
|-----|-------|---------|
| `[clone]` | Green | Repository newly cloned |
| `[pull]` | Cyan | Existing repository successfully updated |
| `[skip]` | Dim | Repository already present, update skipped (`--no-update`) |
| `[keep]` | Yellow | Archived project not deleted — has local changes |
| `[delete]` | Magenta | Local copy of archived project removed |
| `[WARN]` | Yellow | `git pull --ff-only` failed (e.g. local commits present) |
| `[FAIL]` | Red | `git clone` failed |
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
[WARN]   legacy/old-api – could not fast-forward, skipping

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

### Parallel execution

Clones and pulls are dispatched as background jobs with a concurrency limit of 6 (controlled by `PARALLEL_JOBS` inside the script). The main loop uses `wait -n` to consume finished jobs as new ones are added, keeping the pipeline full without exceeding the cap.

### Update strategy

Existing repositories are updated with `git pull --ff-only --quiet`. This ensures that only clean, non-diverged branches are advanced. If a fast-forward is not possible (e.g. due to local commits), a `[WARN]` is emitted and the repository is left unchanged — no force-reset, no data loss.

### Safe deletion of archived projects

When `--delete-archived` is used, the script fetches the list of archived projects from GitLab and checks each local counterpart for:

1. Uncommitted changes (`git status --porcelain`)
2. Unpushed commits (`git diff HEAD @{u}`)

Only repositories that are completely clean on both counts are deleted. All others are logged as `[keep]` with the specific reason.

### Counter tracking across subshells

Because `git clone` and `git pull` run in background subshells (`&`), standard shell variables cannot be shared back to the parent. Counters are maintained as single-line files in a temporary directory (`mktemp -d`) that all subshells can read and write atomically. The temp directory is cleaned up on exit via `trap`.

### API pagination

The GitLab Projects API is paginated at 100 results per page. The script iterates pages until an empty response is received, up to a safety cap of 50 pages (5,000 projects). Both active and archived project lists are fetched independently and can be combined as needed by the flags.

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

## License

MIT License — Copyright (c) 2026 meinestadt.de GmbH, Author: Robert Wachtel.
See the [LICENSE](LICENSE) header inside the script for the full license text.
