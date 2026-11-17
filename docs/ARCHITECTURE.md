# Architecture & porting guide — Sarkhans Claude Starter

This document is for developers who maintain the starter or port the desktop app (e.g. to Windows).

## Components

```
sarkhans-claude-starter/
├── .github/workflows/release.yml ← builds and publishes a release when VERSION changes on main
├── claude-web-starter/          ← the product: cross-platform Node.js installer + template
│   ├── install.mjs              ← CLI (the only thing the desktop app talks to)
│   ├── VERSION                  ← starter version (semver)
│   ├── skills-catalog.json      ← design skills / MCP servers offered in the app
│   ├── global/CLAUDE.md         ← personal rules merged into ~/.claude/CLAUDE.md
│   ├── template/                ← copied into every project
│   │   ├── CLAUDE.md            ← project rules (placeholders filled by the installer)
│   │   └── .claude/
│   │       ├── settings.json    ← hooks, permissions, attribution off
│   │       ├── rules/*.md       ← always-loaded / path-scoped rules
│   │       ├── skills/*/SKILL.md← playbooks (/orchestrate, /kickoff, /verify, …)
│   │       ├── agents/*.md      ← subagent definitions
│   │       ├── hooks/*.mjs      ← enforcement (Node, no dependencies)
│   │       └── scripts/verify.mjs
│   └── packs/<stack>/rules/*.md ← stack rules copied only when the stack is detected
├── macos-app/                   ← SwiftUI desktop app (macOS), build scripts, update source
└── docs/
```

The desktop app is a thin UI over `install.mjs`. **All logic lives in the Node installer and hooks**, so a Windows app only needs to re-implement the UI and the calls below.

## install.mjs — CLI contract

| Command | Effect |
|---|---|
| `node install.mjs <dir>` | Install (first time) or refresh template files that don't exist yet. Detects stacks, writes CLAUDE.md, `.claude/`, config, `.git/info/exclude` entries, updates `~/.claude` (global rules + attribution off). |
| `node install.mjs <dir> --force` | Update all template files; keeps CLAUDE.md and the user's config values. |
| `node install.mjs <dir> --uninstall` | Remove starter files and catalog skills; CLAUDE.md → CLAUDE.md.bak. |
| `--language <name>` | Set `responseLanguage` (alone = settings-only change; with install = initial value). |
| `--design locked\|open`, `--phase new\|existing` | Settings-only changes (when the starter is already installed). |
| `--add-skill <id>` / `--remove-skill <id>` | Install/remove a catalog item (git clone into `.claude/skills/<skill>` or entry in `.mcp.json`). |
| `--no-recommended` | On a first install, don't add the catalog items marked `recommended` (`all` / `frontend` = has package.json / `react` = react or next dependency). |
| `--register-skill <src> [--pick <name>]` | Add the user's own skill to `~/.claude-starter/my-skills.json`. `src` = local folder, `owner/repo`, or GitHub URL (`/tree/<branch>/<path>` allowed). Exit code **3** + JSON `{"choices":[{name,description}]}` on stdout when the source has several skills → call again with `--pick`. |
| `--unregister-skill <id>` | Remove one of the user's own skills from the list (project copies stay). |
| `--list-skills` | Print catalog with ✔ for installed items. |
| `--shared`, `--no-global`, `--overwrite-claude-md`, `--global`, `--help` | See `--help`. |

Exit code `0` = success, non-zero = failure (message on stderr). Run installs **sequentially** — several processes updating `~/.claude/CLAUDE.md` at once can race.

## Files the app reads (per project)

| Path | Meaning |
|---|---|
| marker files: `package.json`, `go.mod`, `composer.json`, `pyproject.toml`, `requirements.txt`, `setup.py`, `Pipfile`, `manage.py` | project + stack detection |
| `.claude/starter-version` | installed starter version (missing → not installed; `.claude/hooks/guard-bash.mjs` present → legacy "1.0") |
| `.claude/hooks/config.json` | `responseLanguage`, `projectPhase` (`new`/`existing`), `designMode` (`locked`/`open`; missing → `locked` unless phase `new`) |
| `.claude/KICKOFF.md` | kickoff done (new projects) |
| `.claude/skills/<skill>/.catalog-source` | catalog skill installed |
| `.mcp.json` → `mcpServers.<id>` | catalog MCP installed |

App-level files: `~/claude-web-starter/VERSION`, `~/claude-web-starter/skills-catalog.json`, `~/claude-web-starter/template/.claude/skills/*/SKILL.md` (built-in skills, shown read-only), `~/.claude-starter/my-skills.json` (user's own skills, category "My skills"; entries have `path` for local or `repo` + `repoPath` for GitHub). The app embeds `claude-web-starter.zip` + `starter-version.txt` and extracts it to `~/claude-web-starter` (deleting the old folder first) when the embedded version is newer.

## macOS app internals
- **Shareable build** (`make-shareable.sh`, used by `build-app.sh`): compiles `ClaudeStarter.swift` for arm64 and x86_64, merges with `lipo` into `Contents/MacOS/ClaudeStarter`, embeds the starter zip + version, signs (Developer ID if present, otherwise ad-hoc), optionally notarizes (`NOTARY_PROFILE`), and wraps everything in a drag-to-Applications DMG.
- **Dev build** (`build-app.sh --dev`): `launcher.c` → tiny native executable that `exec`s `Resources/launch.sh`, which recompiles the Swift source whenever its hash changes (lets the source be updated in place).
- Node.js discovery: `zsh -lc 'command -v node'`, Homebrew paths, nvm, fnm, volta, asdf, mise. If missing, **Install Node.js** downloads the latest LTS `.pkg` from `https://nodejs.org/dist/index.json` and opens it.
- Git check: Homebrew git or `xcode-select -p`; **Install Git** runs `xcode-select --install`.
- Jobs run through one serial queue. Settings changes are optimistic: the UI updates at once, and the project is re-read from disk when its last queued job finishes. This avoids flicker and races.
- Settings in UserDefaults: `projectsFolder` (its absence shows the first-run setup screen) and `responseLanguage` (default for new projects). The GitHub token for private update sources is stored in the Keychain.

## Self-update (macOS app)
- **Source:** `Contents/Resources/update-repo.txt` (`owner/repo`). Written at build time from `UPDATE_REPO` (the release workflow sets it to this repository), `GITHUB_REPOSITORY` or `macos-app/update-repo.txt`. Without it, updates are off.
- **Check:** when the app opens, or via Check for Updates in the menu or Settings, the app calls `GET https://api.github.com/repos/<repo>/releases/latest`.
  - The release version is the tag without the `v`. It's compared numerically with `CFBundleShortVersionString`.
  - On 401/403/404 it retries with a token: first one saved in the Keychain (service `SarkhansClaudeStarter.github`), otherwise `gh auth token`.
- **Download:** the release's `.zip` asset; for a private repository, through the API asset URL with `Accept: application/octet-stream`. The `Authorization` header is dropped on the redirect to storage.
- **Install:**
  1. Unzip with `ditto`.
  2. Verify that the bundle id matches and that `codesign --verify --deep --strict` passes, and remove quarantine.
  3. A helper script waits for the app to quit, swaps the bundle (and rolls back if the move fails), then reopens it.
  4. If the app's folder isn't writable, the swap runs through `do shell script … with administrator privileges`, so macOS asks for the password. Running from App Translocation (straight from the DMG) is refused with a hint to move the app first.
- **Windows equivalent:** same endpoints, with a `.zip`/`.msix` asset per platform. Pick the asset by name suffix, e.g. `-windows.zip`.

## Porting the app to Windows — checklist
1. **UI** (WinUI 3/.NET, WPF, Tauri, Electron…), same flow as the macOS app:
   - **First run:** a setup checklist covers Node.js (one-click install), Git (one-click install), the projects folder (with a found-projects count) and Claude's default language. "Continue" is enabled once Node.js and the starter files are present.
   - **Main window, sidebar:** a segmented filter (Needs setup / Ready / All, with counts), search, and a multi-select project list showing name, stacks and a status pill (Not set up / Update available / Ready / Working… / Didn't finish). A footer button sets up everything that needs it.
   - **Main window, detail panel:**
     - one project shows a header, one primary action (Set up / Update / Ready / Try again), language, "Protect the current design", project type (Existing/New), skills (built-in list, Recommended with "Turn on recommended", other catalog categories, My skills with "Add your own skill…"), and Maintenance (Repair keeps the chosen skills, Remove; both confirmed);
     - several projects show bulk versions of the same actions;
     - no selection shows an overview with counts.
   - **Feedback:** a toast-style notice after each job ("3 projects are ready", or an error with "Show details"); full installer output goes in an Activity sheet.
   - **Settings window:** projects folder, default language, My skills, Updates (check now, optional GitHub token), versions.
   - **Updates:** an "Update to x.y.z" toolbar button and a sheet with release notes and "Update and restart" (see Self-update).
2. **Embedded starter**: ship `claude-web-starter.zip` + version; extract to `%USERPROFILE%\claude-web-starter` when newer (delete old folder first).
3. **Node discovery**: `where node`, `%ProgramFiles%\nodejs\node.exe`, nvm-windows (`%NVM_SYMLINK%`), volta (`%LOCALAPPDATA%\Volta\bin`), fnm. Setup helper: `winget install OpenJS.NodeJS.LTS` (needs Git for Windows too: `winget install Git.Git`).
4. **Process calls**: `node.exe <starter>\install.mjs <dir> [flags]`, capture stdout+stderr, one at a time.

## Windows: things to verify in the Node parts
These were written cross-platform but have only been tested on macOS/Linux:
- **Hook commands** in `template/.claude/settings.json` use `node "$CLAUDE_PROJECT_DIR/.claude/hooks/x.mjs"`. Check how Claude Code on Windows runs hook commands (shell and env-var expansion) and adjust the command format if needed.
- **guard-bash.mjs** patterns target POSIX shells (`rm -rf`, `sed -i`, redirects). Add PowerShell/cmd equivalents (`Remove-Item -Recurse -Force`, `del /s`, `Set-Content`, `Out-File`) if Claude uses PowerShell there.
- **orchestrator-guard.mjs** detects file writes via POSIX syntax — same as above.
- **lib.mjs**: `findTool` uses `where` on Windows and checks `.cmd`/`.exe` in `node_modules\.bin`, `vendor\bin`, `.venv\Scripts` (add `Scripts` dirs where needed); `run()` uses `shell: true` on Windows.
- **Path handling**: hooks normalize to forward slashes for rule matching; verify on real Windows paths (drive letters, backslashes).
- **Docker**: `docker compose exec -T` works the same with Docker Desktop.
- **Git**: `.git/info/exclude`, branch/commit guards are platform-independent.

## Testing
Each hook reads JSON from stdin, so it can be tested without Claude Code:
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | CLAUDE_PROJECT_DIR=$PWD node .claude/hooks/guard-bash.mjs; echo "exit=$?"
```
Exit code 2 = blocked (stderr is the message Claude sees).
