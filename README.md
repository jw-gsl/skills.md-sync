# skill-sync

Bidirectional skill sync between **Claude Code** and **OpenAI Codex CLI**.

Skills created in one tool automatically appear in the other, with format conversion handled transparently.

## What it does

| Direction | Source | Target |
|-----------|--------|--------|
| Codex -> Claude | `~/.codex/skills/<name>/SKILL.md` | `~/.claude/commands/<name>.md` |
| Claude -> Codex | `~/.claude/commands/<name>.md` | `~/.codex/skills/<name>/SKILL.md` + `agents/openai.yaml` |

- **Content hashing** (md5) detects actual changes, not timestamps
- **Auto-conflict resolution** when both sides change: most recently modified wins
- **Source tracking** prevents sync loops (each synced file is tagged with its origin)
- **macOS toast notifications** via `terminal-notifier` with click-to-open log
- Optional **daily cron** via macOS LaunchAgent

## Quick start

```bash
git clone https://github.com/YOUR_USER/skill-sync.git ~/.skill-sync
cd ~/.skill-sync
chmod +x sync-skills.sh install.sh

# First run: seed from Codex as source of truth
./sync-skills.sh --seed

# Normal sync
./sync-skills.sh

# Install daily cron (8am)
./install.sh
```

## How sync works

1. Script builds a unified list of all skill names from both `~/.codex/skills/` and `~/.claude/commands/`
2. For each skill, it hashes the body content (ignoring frontmatter) on both sides
3. Compares against stored hashes from the last sync run
4. Decides:
   - **Neither changed** -> skip
   - **Only one side changed** -> sync to the other
   - **Both changed** -> auto-resolve (most recently modified wins)
   - **Only exists on one side** -> create on the other
5. Stores new hashes for the next run

## Format conversion

**Codex SKILL.md** has `name` + `description` frontmatter and a markdown body with workflow instructions.

**Claude commands** have `description` frontmatter and the same body. A `source: codex-sync` tag prevents re-syncing back.

**Codex openai.yaml** is auto-generated with `display_name`, `short_description`, and `default_prompt`.

## Configuration

Override default paths via environment variables:

```bash
CODEX_SKILLS_DIR=~/my-codex-skills CLAUDE_COMMANDS_DIR=~/my-claude-cmds ./sync-skills.sh
```

## Requirements

- macOS (uses `md5 -q` and `stat -f %m`)
- `python3` (for JSON hash storage)
- `terminal-notifier` (optional, for toast notifications): `brew install terminal-notifier`

## License

MIT
