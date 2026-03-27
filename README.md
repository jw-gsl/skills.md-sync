# skills.md-sync

Multi-tool AI skill sync using the [SKILL.md open standard](https://agentskills.io/specification).

Create a skill in **any** AI CLI tool and it automatically appears in all the others.

## Supported tools

| Tool | Skills location | Auto-detected |
|------|----------------|---------------|
| **Claude Code** | `~/.claude/skills/` | Yes (if `~/.claude/` exists) |
| **Codex CLI** | `~/.codex/skills/` | Yes (if `~/.codex/` exists) |
| **Gemini CLI** | `~/.gemini/skills/` | Yes (if `~/.gemini/` exists) |
| **GitHub Copilot** | `~/.copilot/skills/` | Yes (if `~/.copilot/` exists) |

All tools use the standard `SKILL.md` format. Codex additionally gets `agents/openai.yaml` auto-generated.

## Architecture

```
~/.skills/                  <-- canonical store (source of truth)
  ├── my-skill/SKILL.md
  └── another-skill/SKILL.md

Synced to all detected tools:
  ~/.claude/skills/         <-- Claude Code
  ~/.codex/skills/          <-- Codex CLI (+ openai.yaml)
  ~/.gemini/skills/         <-- Gemini CLI
  ~/.copilot/skills/        <-- GitHub Copilot
```

## Quick start

```bash
git clone https://github.com/jw-gsl/skills.md-sync.git
cd skills.md-sync
chmod +x sync-skills.sh install.sh

# See what tools are detected
./sync-skills.sh --status

# First run: import all existing skills from all tools
./sync-skills.sh --seed

# Normal sync
./sync-skills.sh

# Install daily cron (8am, macOS only)
./install.sh
```

## How it works

1. Scans all detected tool skill directories for `SKILL.md` files
2. Builds a unified list of skill names across all tools
3. For each skill, hashes the body content (ignoring frontmatter) on every side
4. Compares against stored hashes from the last run
5. If any tool's copy changed, the **most recently modified version wins** and is pushed to all others via the canonical store
6. Stores updated hashes for the next run

No manual conflict resolution needed — newest edit always wins.

## Commands

| Command | Description |
|---------|-------------|
| `./sync-skills.sh` | Normal sync — detect changes and propagate |
| `./sync-skills.sh --seed` | Import all existing skills, baseline hashes |
| `./sync-skills.sh --status` | Show detected tools and skill counts |

## Notifications

On macOS, uses `terminal-notifier` for toast notifications when skills are synced. Clicking the notification opens the sync log.

- **1 skill:** `✅ Synced: my-skill`
- **Multiple:** `✅ 5 synced: my-skill +4 more`

Install with: `brew install terminal-notifier`

## Configuration

Override the canonical store location:

```bash
SKILLS_DIR=~/my-skills ./sync-skills.sh
```

## Adding a new tool

Edit `declare_tools()` in `sync-skills.sh`. Each tool just needs a name and the path where it expects `<skill-name>/SKILL.md` directories.

## Requirements

- macOS or Linux
- `python3` (for JSON hash storage)
- `terminal-notifier` (optional, macOS toast notifications)

## License

MIT
