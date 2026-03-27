#!/usr/bin/env bash
# sync-skills.sh — Bidirectional skill sync between Claude Code and Codex
#
# Codex format:  ~/.codex/skills/<name>/SKILL.md + agents/openai.yaml
# Claude format:  ~/.claude/commands/<name>.md (frontmatter + instructions)
#
# Sync logic:
# - Uses content hashing (md5) to detect actual changes
# - Stores last-synced hashes in hashes.json
# - If only one side changed → sync that direction
# - If both sides changed → flag CONFLICT
# - Use --seed to baseline from Codex as source of truth
#
# Run manually or via daily cron.

set -euo pipefail

CODEX_SKILLS="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
CLAUDE_COMMANDS="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
SYNC_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_LOG="$SYNC_DIR/sync.log"
HASH_STORE="$SYNC_DIR/hashes.json"
SYNCED_SKILLS=()
AUTO_RESOLVED=0

# Batch hash updates — collected here, flushed at end
HASH_UPDATES=""

mkdir -p "$CLAUDE_COMMANDS"
mkdir -p "$CODEX_SKILLS"
[ -f "$HASH_STORE" ] || echo '{}' > "$HASH_STORE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SYNC_LOG"; }

notify() {
    local title="$1"
    local message="$2"
    local open_target="${3:-}"
    if command -v terminal-notifier >/dev/null 2>&1; then
        local args=(-title "$title" -message "$message" -group "skill-sync")
        [[ -n "$open_target" ]] && args+=(-open "$open_target")
        nohup terminal-notifier "${args[@]}" >/dev/null 2>&1 &
    else
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
    fi
}

content_hash() {
    local file="$1"
    if [ -f "$file" ]; then
        awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$file" | md5 -q 2>/dev/null || echo "ERR"
    else
        echo "MISSING"
    fi
}

# Load all hashes once into a flat file for fast lookups (no python per call)
HASH_CACHE=$(mktemp)
python3 -c "
import json
with open('$HASH_STORE') as f: d=json.load(f)
for k,v in d.items(): print(f'{k}={v}')
" > "$HASH_CACHE" 2>/dev/null || true

get_stored_hash() {
    local key="$1"
    local line
    line=$(grep "^${key}=" "$HASH_CACHE" 2>/dev/null | head -1) || true
    echo "${line#*=}"
}

queue_hash() {
    local key="$1" value="$2"
    HASH_UPDATES="${HASH_UPDATES}${key}=${value}\n"
}

flush_hashes() {
    [ -z "$HASH_UPDATES" ] && return
    printf "$HASH_UPDATES" | python3 -c "
import json, sys
with open('$HASH_STORE','r') as f: d=json.load(f)
for line in sys.stdin:
    line=line.strip()
    if '=' in line:
        k,v = line.split('=',1)
        d[k]=v
with open('$HASH_STORE','w') as f: json.dump(d,f,indent=2,sort_keys=True)
" 2>/dev/null
}

extract_description() {
    awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description: */, ""); print}' "$1"
}

extract_body() {
    awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$1"
}

# ── Codex → Claude ──────────────────────────────────────────────────────

codex_to_claude() {
    local skill_name="$1" codex_file="$2" claude_file="$3"
    local description body
    description=$(extract_description "$codex_file")
    [ -z "$description" ] && description="Synced from Codex skill: $skill_name"
    body=$(extract_body "$codex_file")

    cat > "$claude_file" <<CLAUDE_EOF
---
description: $description
source: codex-sync
---

$body
CLAUDE_EOF

    queue_hash "${skill_name}_codex" "$(content_hash "$codex_file")"
    queue_hash "${skill_name}_claude" "$(content_hash "$claude_file")"
    SYNCED_SKILLS+=("Codex -> Claude: $skill_name")
    log "  [SYNC]     Codex -> Claude: $skill_name"
    log "             Description: ${description:0:100}"
}

# ── Claude → Codex ──────────────────────────────────────────────────────

claude_to_codex() {
    local skill_name="$1" claude_file="$2"
    local codex_dir="$CODEX_SKILLS/$skill_name"
    local codex_file="$codex_dir/SKILL.md"
    mkdir -p "$codex_dir/agents"

    local description body
    description=$(extract_description "$claude_file")
    [ -z "$description" ] && description="Synced from Claude command: $skill_name"
    body=$(extract_body "$claude_file")

    cat > "$codex_file" <<CODEX_EOF
---
name: $skill_name
description: $description
source: claude-sync
---

# $skill_name

$body
CODEX_EOF

    cat > "$codex_dir/agents/openai.yaml" <<YAML_EOF
interface:
  display_name: "$skill_name"
  short_description: "$description"
  default_prompt: "Use \$${skill_name} to help with this task."
YAML_EOF

    queue_hash "${skill_name}_codex" "$(content_hash "$codex_file")"
    queue_hash "${skill_name}_claude" "$(content_hash "$claude_file")"
    SYNCED_SKILLS+=("Claude -> Codex: $skill_name")
    log "  [SYNC]     Claude -> Codex: $skill_name"
    log "             Description: ${description:0:100}"
}

# ── Seed mode ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--seed" ]]; then
    > "$SYNC_LOG"
    echo '{}' > "$HASH_STORE"
    log "======= SEED MODE: Codex is source of truth ======="
    for skill_dir in "$CODEX_SKILLS"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        [[ "$skill_name" == .* ]] && continue
        [ -f "$skill_dir/SKILL.md" ] || continue
        codex_to_claude "$skill_name" "$skill_dir/SKILL.md" "$CLAUDE_COMMANDS/${skill_name}.md"
        log "  [SEED] $skill_name"
    done
    flush_hashes
    log "Seed complete. ${#SYNCED_SKILLS[@]} skills baselined."
    notify "🌱 Skill Sync" "✅ Seeded: ${#SYNCED_SKILLS[@]} skills baselined" "file://$SYNC_LOG"
    echo "🌱 Seed complete. ${#SYNCED_SKILLS[@]} skills baselined."
    exit 0
fi

# ── Normal sync ─────────────────────────────────────────────────────────

codex_count=$(find "$CODEX_SKILLS" -maxdepth 1 -mindepth 1 -type d -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')
claude_count=$(find "$CLAUDE_COMMANDS" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

log "========================================================"
log "Skill Sync Started"
log "  Codex skills:    $codex_count ($CODEX_SKILLS)"
log "  Claude commands: $claude_count ($CLAUDE_COMMANDS)"
log "--------------------------------------------------------"

# Build unified skill list (bash 3 compatible)
all_skills_file=$(mktemp)

for skill_dir in "$CODEX_SKILLS"/*/; do
    [ -d "$skill_dir" ] || continue
    name=$(basename "$skill_dir")
    [[ "$name" == .* ]] && continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    echo "$name" >> "$all_skills_file"
done

for cmd_file in "$CLAUDE_COMMANDS"/*.md; do
    [ -f "$cmd_file" ] || continue
    echo "$(basename "$cmd_file" .md)" >> "$all_skills_file"
done

for skill_name in $(sort -u "$all_skills_file"); do
    codex_file="$CODEX_SKILLS/$skill_name/SKILL.md"
    claude_file="$CLAUDE_COMMANDS/${skill_name}.md"

    codex_exists=false; claude_exists=false
    [ -f "$codex_file" ] && codex_exists=true
    [ -f "$claude_file" ] && claude_exists=true

    codex_hash="MISSING"; claude_hash="MISSING"
    $codex_exists && codex_hash=$(content_hash "$codex_file")
    $claude_exists && claude_hash=$(content_hash "$claude_file")

    stored_codex=$(get_stored_hash "${skill_name}_codex")
    stored_claude=$(get_stored_hash "${skill_name}_claude")

    codex_changed=false; claude_changed=false
    [ "$codex_hash" != "$stored_codex" ] && codex_changed=true
    [ "$claude_hash" != "$stored_claude" ] && claude_changed=true

    if ! $codex_changed && ! $claude_changed; then
        log "  [OK]       $skill_name"
        continue
    fi

    if $codex_exists && ! $claude_exists; then
        codex_to_claude "$skill_name" "$codex_file" "$claude_file"
        continue
    fi

    if $claude_exists && ! $codex_exists; then
        if ! grep -q "^source: codex-sync" "$claude_file" 2>/dev/null; then
            claude_to_codex "$skill_name" "$claude_file"
        fi
        continue
    fi

    # Both exist
    if $codex_changed && ! $claude_changed; then
        codex_to_claude "$skill_name" "$codex_file" "$claude_file"
    elif $claude_changed && ! $codex_changed; then
        claude_to_codex "$skill_name" "$claude_file"
    elif $codex_changed && $claude_changed; then
        # Both changed — auto-resolve by picking the most recently modified
        local codex_mtime claude_mtime
        codex_mtime=$(stat -f %m "$codex_file" 2>/dev/null || echo 0)
        claude_mtime=$(stat -f %m "$claude_file" 2>/dev/null || echo 0)
        if [ "$codex_mtime" -ge "$claude_mtime" ]; then
            log "  [AUTO]     $skill_name — both changed, Codex is newer -> syncing Codex to Claude"
            codex_to_claude "$skill_name" "$codex_file" "$claude_file"
        else
            log "  [AUTO]     $skill_name — both changed, Claude is newer -> syncing Claude to Codex"
            claude_to_codex "$skill_name" "$claude_file"
        fi
    fi
done

rm -f "$all_skills_file" "$HASH_CACHE"
flush_hashes

log "--------------------------------------------------------"
log "Result: ${#SYNCED_SKILLS[@]} synced"
for s in "${SYNCED_SKILLS[@]+"${SYNCED_SKILLS[@]}"}"; do
    [ -n "$s" ] && log "  + $s"
done
log "========================================================"
log ""

# Notifications
LOG_URL="file://$SYNC_LOG"
if [ ${#SYNCED_SKILLS[@]} -gt 0 ]; then
    count=${#SYNCED_SKILLS[@]}
    first_name=$(printf '%s\n' "${SYNCED_SKILLS[0]}" | sed 's/.*: //')
    if [ "$count" -eq 1 ]; then
        notify "🔄 Skill Sync" "✅ Synced: $first_name" "$LOG_URL"
    else
        notify "🔄 Skill Sync" "✅ $count synced: $first_name +$((count - 1)) more" "$LOG_URL"
    fi
    echo "✅ Synced $count skill(s):"
    printf '  🔗 %s\n' "${SYNCED_SKILLS[@]}"
else
    echo "✨ All skills up to date."
fi
