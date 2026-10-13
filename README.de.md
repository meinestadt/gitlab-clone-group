# gitlab-clone-group

[English](README.md) | Deutsch

Zwei Bash-Skripte, die lokale Git-Repositories mit ihren Remotes synchron halten, ohne lokale Arbeit anzufassen:

- **`gitlab-clone-group.sh`** klont alle Projekte einer GitLab-Gruppe in ein lokales Verzeichnis, behält dabei die komplette Namespace-Struktur bei und hält bestehende Klone mit GitLab abgeglichen (umbenannte, verschobene, archivierte und entfernte Projekte). Gedacht für Teams, die eine verlässliche, wiederholbare Möglichkeit brauchen, eine ganze GitLab-Gruppe – inklusive Untergruppen – auf einen lokalen Rechner zu spiegeln oder zu synchronisieren.
- **`update-repos.sh`** aktualisiert jedes Git-Repository unterhalb eines Verzeichnisses, egal von welchem Host (GitLab, GitHub, andere): Es holt alle Remotes und spult lokale Branches vor (Fast-Forward).

Zusammen ergeben sie einen vollständigen Sync: Das erste findet und klont neue Projekte, das zweite aktualisiert alles (siehe [Komplett-Sync](#komplett-sync)).

## Funktionen

- Klont alle aktiven Projekte einer GitLab-Gruppe und ihrer Untergruppen
- Bildet die Namespace-Hierarchie als lokalen Verzeichnisbaum ab
- Aktualisiert bereits geklonte Repositories standardmäßig per `git pull --ff-only`
- Erkennt bestehende Klone an GitLab-Projekt-ID oder Remote-URL (ssh und https), unabhängig vom lokalen Pfad
- Folgt umbenannten und verschobenen Projekten: aktualisiert `origin` und meldet die Verschiebung, statt doppelt zu klonen
- Meldet doppelte Klone und Klone, deren Projekt die Gruppe verlassen hat
- Parallele Ausführung (standardmäßig 6 gleichzeitige Jobs) für schnellen Betrieb bei großen Gruppen
- Optionales Einbeziehen archivierter Projekte
- Sicheres Aufräumen lokaler Klone von Projekten, die auf GitLab archiviert wurden
  (Verschieben in einen `.trash`-Ordner, und nur wenn nichts uncommittet, gestasht oder ungepusht ist)
- Farbige Ausgabe für schnellen Überblick (in Nicht-TTY-Umgebungen automatisch deaktiviert)
- Zusammenfassung am Ende jedes Laufs
- Konfiguration über CLI-Flags oder Umgebungsvariablen

## Voraussetzungen

| Tool | Zweck |
|------|-------|
| [`glab`](https://gitlab.com/gitlab-org/cli) | GitLab CLI, muss authentifiziert sein |
| `git` | Klonen und Pullen von Repositories |
| `python3` | JSON-Verarbeitung der GitLab-API-Antworten |
| `bash` 3.2+ | Laufzeitumgebung (die macOS-System-Bash funktioniert) |

### glab installieren

```bash
# macOS
brew install glab

# Linux (Homebrew)
brew install glab

# Andere Plattformen: https://gitlab.com/gitlab-org/cli#installation
```

Nach der Installation gegen die eigene GitLab-Instanz authentifizieren:

```bash
glab auth login --hostname git.example.com
```

## Installation

```bash
# Dieses Repository klonen
git clone https://github.com/meinestadt/gitlab-clone-group.git

# Skripte ausführbar machen
chmod +x gitlab-clone-group/gitlab-clone-group.sh gitlab-clone-group/update-repos.sh

# Optional global installieren
cp gitlab-clone-group/gitlab-clone-group.sh /usr/local/bin/gitlab-clone-group
cp gitlab-clone-group/update-repos.sh /usr/local/bin/update-repos
```

## Verwendung

```
gitlab-clone-group.sh --host HOST --group ID --dir PATH [OPTIONS]
```

### Pflichtparameter

Alle drei Pflichtparameter können als CLI-Flags übergeben oder über Umgebungsvariablen gesetzt werden. CLI-Flags haben immer Vorrang.

| Flag | Umgebungsvariable | Beschreibung |
|------|-------------------|--------------|
| `--host HOST` | `GITLAB_CLONE_HOST` | GitLab-Hostname (z. B. `gitlab.example.com`) |
| `--group ID` | `GITLAB_CLONE_GROUP_ID` | Numerische Gruppen-ID oder vollständiger Pfad (z. B. `1879` oder `myorg/myteam`) |
| `--dir PATH` | `GITLAB_CLONE_TARGET_DIR` | Lokales Zielverzeichnis |

Existiert das Zielverzeichnis nicht, fragt das Skript vor dem Anlegen nach.

### Optionen

| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `-a`, `--archived` | aus | Archivierte Projekte ebenfalls klonen |
| `-n`, `--no-update` | aus | Kein `git pull` für bereits geklonte Repositories |
| `-d`, `--delete-archived` | aus | Lokale Kopien von auf GitLab archivierten Projekten nach `PATH/.trash` verschieben (nur wenn sauber, siehe unten). Nicht mit `-a` kombinierbar |
| `-h`, `--help` | | Hilfe anzeigen |

## Beispiele

### Erstes Klonen einer Gruppe

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup
```

### Täglicher Sync über Umgebungsvariablen

```bash
export GITLAB_CLONE_HOST=git.example.com
export GITLAB_CLONE_GROUP_ID=1879
export GITLAB_CLONE_TARGET_DIR=~/Projects/mygroup

gitlab-clone-group.sh
```

### Alles klonen, inklusive archivierter Projekte

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group myorg/myteam \
  --dir ~/Projects/myteam \
  --archived
```

### Synchronisieren und lokal archivierte Projekte entfernen

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup \
  --delete-archived
```

### Nur klonen, bestehende Repositories nicht aktualisieren

```bash
gitlab-clone-group.sh \
  --host git.example.com \
  --group 1879 \
  --dir ~/Projects/mygroup \
  --no-update
```

### Cronjob (täglicher Sync um 06:00)

```cron
0 6 * * * GITLAB_CLONE_HOST=git.example.com GITLAB_CLONE_GROUP_ID=1879 GITLAB_CLONE_TARGET_DIR=/srv/mirror /usr/local/bin/gitlab-clone-group >> /var/log/gitlab-clone-group.log 2>&1
```

## Alle Repositories aktualisieren (`update-repos.sh`)

```
update-repos.sh [DIRECTORY] [MAX_PARALLEL]
```

| Argument | Standard | Beschreibung |
|----------|----------|--------------|
| `DIRECTORY` | aktuelles Verzeichnis | Wird rekursiv nach Git-Repositories durchsucht |
| `MAX_PARALLEL` | `8` | Maximale Anzahl gleichzeitig bearbeiteter Repositories |

`update-repos.sh` braucht nur `git` und arbeitet mit jedem gefundenen Repository, egal woher es geklont wurde. Ordner namens `node_modules`, `.venv`, `vendor`, `target` und `.trash` werden bei der Suche übersprungen. Für jedes Repository:

1. Führt `git fetch --all --prune` aus. Das aktualisiert die Remote-Tracking-Branches aller Remotes und fasst das Arbeitsverzeichnis nie an.
2. Spult jeden anderen lokalen Branch vor, der echt hinter seinem Upstream liegt. Divergierte Branches und Branches, die in einem anderen Worktree ausgecheckt sind, bleiben unverändert.
3. Spult den ausgecheckten Branch mit `git merge --ff-only @{u}` vor. Git verweigert das, wenn eine Änderung uncommittete oder ungetrackte Dateien überschreiben würde oder der Branch divergiert ist.

| Status | Bedeutung |
|--------|-----------|
| `OK` | Geholt und vorgespult (oder bereits aktuell); `+N other branch(es)` zählt zusätzlich vorgespulte Branches |
| `SKIP` | Kein Remote, detached HEAD, oder der aktuelle Branch hat keinen Upstream (andere Branches werden trotzdem geholt und vorgespult) |
| `FAIL` | Fetch oder Fast-Forward fehlgeschlagen; der Grund von Git steht in der Zusammenfassung |

Es wird nie gemergt, rebased, zurückgesetzt oder gelöscht. Lokale Commits, uncommittete Änderungen und ungetrackte Dateien bleiben unverändert.

## Komplett-Sync

`gitlab-clone-group.sh` findet und klont neue Projekte (und folgt verschobenen), danach aktualisiert `update-repos.sh` alles, auch Repositories von anderen Hosts:

```bash
gitlab-clone-group.sh --host git.example.com --group mygroup --dir ~/Projects/mygroup --no-update \
  && update-repos.sh ~/Projects
```

## Ausgabe

Das Skript nutzt farbige Logzeilen (automatisch abgeschaltet, wenn die Ausgabe umgeleitet oder gepipet wird):

| Tag | Farbe | Bedeutung |
|-----|-------|-----------|
| `[clone]` | Grün | Repository neu geklont |
| `[pull]` | Cyan | Bestehendes Repository erfolgreich aktualisiert |
| `[skip]` | Gedimmt | Repository bereits vorhanden, Update übersprungen (`--no-update`) |
| `[moved]` | Cyan | Projekt auf GitLab umbenannt oder verschoben – `origin` aktualisiert, Ordner bleibt an seinem Platz |
| `[keep]` | Gelb | Archiviertes Projekt nicht in den Papierkorb verschoben (hat lokale Arbeit) oder doppelter Klon |
| `[gone]` | Gelb | Lokaler Klon, dessen Projekt nicht mehr in der Gruppe ist (verschoben oder gelöscht) |
| `[trash]` | Magenta | Lokale Kopie eines archivierten Projekts nach `.trash` verschoben |
| `[WARN]` | Gelb | `git pull --ff-only` fehlgeschlagen – der Grund von Git wird angezeigt |
| `[FAIL]` | Rot | `git clone` fehlgeschlagen – der Grund von Git wird angezeigt |
| `[ERROR]` | Rot | API- oder Konfigurationsfehler |

### Beispielausgabe

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

## Funktionsweise

### Verzeichnisstruktur

Das Skript bildet die GitLab-Namespace-Hierarchie lokal ab. Für eine Gruppe `myorg` mit dem Pfad `myorg/team-a/service-x` sieht das lokale Layout so aus:

```
~/Projects/mygroup/
└── team-a/
    └── service-x/
```

Das oberste Gruppenpräfix (`myorg/`) wird automatisch entfernt – das Skript ermittelt es über die GitLab-Groups-API und funktioniert daher sowohl mit numerischen Gruppen-IDs als auch mit Pfaden.

### Zuordnung lokaler Klone zu GitLab-Projekten

Bevor etwas geklont wird, indiziert das Skript jedes Git-Repository unter dem Zielverzeichnis und ordnet es der Projektliste zu:

1. Über die GitLab-Projekt-ID in der Konfiguration des Klons (`git config gitlab.projectId`). Das Skript schreibt diese ID bei jedem Klon und bei jedem erkannten bestehenden Klon, damit spätere Umbenennungen und Verschiebungen zuverlässig verfolgt werden.
2. Sonst über die normalisierte `origin`-URL. `git@host:group/x.git` und `https://host/group/x.git` gelten als dasselbe Projekt, sodass Klone in einem anderen Ordnerlayout oder mit anderem Protokoll nicht erneut geklont werden.
3. Bei einem Klon innerhalb der Gruppe, dessen URL zu keinem Projekt passt, fragt das Skript die GitLab-API einmal nach dem alten Pfad. GitLab löst umbenannte und verschobene Projekte auf ihren neuen Ort auf, sodass auch Verschiebungen aus der Zeit vor der ID-Verfolgung erkannt werden.

Ein zugeordneter Klon, dessen `origin` noch auf einen alten Pfad innerhalb der Gruppe zeigt, bekommt ein aktualisiertes `origin` (ssh bzw. https bleibt erhalten) und wird als `[moved]` gemeldet. Der Ordner bleibt, wo er ist, damit IDE-Projekte und offene Terminals weiter funktionieren. Ein zweiter Klon desselben Projekts wird als Duplikat gemeldet und nicht aktualisiert. Ein Klon, dessen Projekt nicht mehr in der Gruppe ist, wird als `[gone]` gemeldet und nicht angefasst.

Ein Klon, dessen `origin` woanders hin zeigt (Fork oder Mirror) oder der kein `origin` hat, behält seine Remotes unverändert.

Wenn die Gruppe nicht aufgelöst werden kann, die API keine Projekte liefert oder die Liste das `MAX_PAGES`-Limit erreicht, bricht das Skript ab, statt in falsche Ordner zu klonen oder Klone fälschlich als verschwunden zu melden.

### Parallele Ausführung

Klone und Pulls laufen als Hintergrund-Jobs mit einem Limit von 6 gleichzeitigen Jobs (gesteuert über `PARALLEL_JOBS` im Skript). Die Hauptschleife wartet auf einen freien Platz, bevor sie den nächsten Job startet.

### Update-Strategie

Bestehende Repositories werden mit `git pull --ff-only --quiet` aktualisiert. Dadurch werden nur nicht divergierte Branches vorgespult und lokale Änderungen nie überschrieben. Ist kein Fast-Forward möglich (z. B. divergierte lokale Commits oder uncommittete Änderungen an Dateien, die das Update betrifft), erscheint ein `[WARN]` mit dem Grund von Git und das Repository bleibt unverändert – kein Force-Reset, kein Datenverlust.

### Sicheres Löschen archivierter Projekte

Mit `--delete-archived` wird jeder lokale Klon eines archivierten Projekts auf Arbeit geprüft, die es nirgendwo sonst gibt:

1. Uncommittete Änderungen oder ungetrackte Dateien (`git status --porcelain`)
2. Gestashte Änderungen (`git stash list`)
3. Commits auf einem lokalen Branch oder einem detached HEAD, die auf keinem Remote liegen (`git log --branches HEAD --not --remotes`)
4. Verknüpfte Worktrees (`git worktree list`), die durch das Verschieben kaputtgehen würden

Schlägt einer dieser Git-Befehle fehl, gilt der Klon als unsicher. Klone, die alle vier Prüfungen bestehen, werden nach `PATH/.trash/<path>.<timestamp>` verschoben, nie gelöscht – von Git ignorierte Dateien wie `.env` bleiben also erhalten. Den Papierkorb leert man selbst, wenn man ihn nicht mehr braucht. Alle anderen Klone werden mit dem konkreten Grund als `[keep]` protokolliert.

### Zähler über Subshells hinweg

Da `git clone` und `git pull` in Hintergrund-Subshells (`&`) laufen, können normale Shell-Variablen nicht an den Elternprozess zurückgegeben werden. Jedes Ereignis hängt eine Zeile an eine Zählerdatei in einem temporären Verzeichnis (`mktemp -d`) an; die Zusammenfassung zählt die Zeilen, sodass parallele Jobs keine Zählung verlieren. Das temporäre Verzeichnis wird beim Beenden per `trap` aufgeräumt.

### API-Paginierung

Die GitLab-Projects-API liefert 100 Ergebnisse pro Seite. Das Skript iteriert über die Seiten, bis eine leere Antwort kommt, höchstens bis zum Sicherheitslimit von 50 Seiten (5.000 Projekte). Aktive und archivierte Projektlisten werden immer beide geholt, damit Klone archivierter Projekte nicht als verschwunden gelten.

## Konfigurationsreferenz

| Parameter | Typ | Standard | Beschreibung |
|-----------|-----|----------|--------------|
| `GITLAB_CLONE_HOST` | env / `--host` | — | GitLab-Hostname (Pflicht) |
| `GITLAB_CLONE_GROUP_ID` | env / `--group` | — | GitLab-Gruppen-ID oder -Pfad (Pflicht) |
| `GITLAB_CLONE_TARGET_DIR` | env / `--dir` | — | Lokales Klon-Ziel (Pflicht) |
| `PER_PAGE` | Skriptkonstante | `100` | API-Ergebnisse pro Seite |
| `MAX_PAGES` | Skriptkonstante | `50` | Maximale Anzahl abgerufener Seiten (Sicherheitslimit) |
| `PARALLEL_JOBS` | Skriptkonstante | `6` | Maximale Anzahl gleichzeitiger Clone-/Pull-Jobs |

`PER_PAGE`, `MAX_PAGES` und `PARALLEL_JOBS` lassen sich über die Konstanten am Anfang des Skripts anpassen.

## Tests

Beide Testsuiten laufen offline gegen lokale Bare-Repositories:

- `test/run-tests.sh` testet `gitlab-clone-group.sh` mit einem Fake-`glab`: Klonen, Zuordnung, Verschiebungen, verschwundene und doppelte Klone sowie die Sicherheitsprüfungen für archivierte Projekte.
- `test/update-repos.test.sh` testet `update-repos.sh`: Fast-Forward, erhaltene lokale Änderungen, Worktree- und divergierte Branches, mehrere Remotes und Skip-Gründe.

```bash
test/run-tests.sh
test/update-repos.test.sh
```

## Lizenz

MIT-Lizenz — Copyright (c) 2026 meinestadt.de GmbH, Autor: Robert Wachtel.
Den vollständigen Lizenztext enthält der Header von `gitlab-clone-group.sh`.
