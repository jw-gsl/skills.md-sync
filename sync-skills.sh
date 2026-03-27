#!/usr/bin/env bash
# sync-skills.sh — Multi-tool AI skill sync
#
# Maintains a canonical SKILL.md store and syncs to all detected AI CLI tools.
# Supports: Claude Code, Codex, Gemini CLI, GitHub Copilot, Cursor
#
# Architecture:
# - Canonical store: ~/.skills/ (SKILL.md standard format)
# - Each tool gets a copy/symlink in its expected location
# - Content hashing detects real changes
# - Newest version wins when multiple tools edit the same skill
#
# Usage:
#   ./sync-skills.sh          Normal sync
#   ./sync-skills.sh --seed   Import all existing skills from all tools
#   ./sync-skills.sh --status Show detected tools and skill counts

set -euo pipefail

CANONICAL="${SKILLS_DIR:-$HOME/.skills}"
SYNC_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_LOG="$SYNC_DIR/sync.log"
HASH_STORE="$SYNC_DIR/hashes.json"
SYNCED=()
HASH_UPDATES=""

mkdir -p "$CANONICAL"
[ -f "$HASH_STORE" ] || echo '{}' > "$HASH_STORE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SYNC_LOG"; }

notify() {
    local title="$1" message="$2" open_target="${3:-}"
    if command -v terminal-notifier >/dev/null 2>&1; then
        local args=(-title "$title" -message "$message" -group "skill-sync")
        [[ -n "$open_target" ]] && args+=(-open "$open_target")
        nohup terminal-notifier "${args[@]}" >/dev/null 2>&1 &
    else
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
    fi
}

content_hash() {
    if [ -f "$1" ]; then
        awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$1" | md5 -q 2>/dev/null || echo "ERR"
    else
        echo "MISSING"
    fi
}

# Load hash cache once
HASH_CACHE=$(mktemp)
python3 -c "
import json
with open('$HASH_STORE') as f: d=json.load(f)
for k,v in d.items(): print(f'{k}={v}')
" > "$HASH_CACHE" 2>/dev/null || true

get_hash() {
    local line
    line=$(grep "^${1}=" "$HASH_CACHE" 2>/dev/null | head -1) || true
    echo "${line#*=}"
}

queue_hash() { HASH_UPDATES="${HASH_UPDATES}${1}=${2}\n"; }

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

extract_name() {
    awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name: */, ""); print}' "$1"
}

extract_body() {
    awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$1"
}

# ── Tool detection ──────────────────────────────────────────────────────

declare_tools() {
    # Each tool: NAME|SKILLS_DIR|FORMAT|INSTALLED
    # FORMAT: skill.md = standard SKILL.md, command.md = Claude commands, toml = Gemini commands
    TOOLS=()

    # Canonical store (always present)
    TOOLS+=("canonical|$CANONICAL|skill.md|yes")

    # Claude Code — skills dir (SKILL.md standard)
    local claude_skills="$HOME/.claude/skills"
    if [ -d "$HOME/.claude" ]; then
        mkdir -p "$claude_skills"
        TOOLS+=("claude|$claude_skills|skill.md|yes")
    fi

    # Codex — skills dir (SKILL.md + agents/openai.yaml)
    local codex_skills="$HOME/.codex/skills"
    if [ -d "$HOME/.codex" ]; then
        TOOLS+=("codex|$codex_skills|skill.md|yes")
    fi

    # Gemini CLI — skills dir (SKILL.md standard)
    local gemini_skills="$HOME/.gemini/skills"
    if [ -d "$HOME/.gemini" ]; then
        mkdir -p "$gemini_skills"
        TOOLS+=("gemini|$gemini_skills|skill.md|yes")
    fi

    # GitHub Copilot — skills dir
    local copilot_skills="$HOME/.copilot/skills"
    if [ -d "$HOME/.copilot" ]; then
        mkdir -p "$copilot_skills"
        TOOLS+=("copilot|$copilot_skills|skill.md|yes")
    fi
}

# ── Read a skill from any tool location ─────────────────────────────────

find_skill_file() {
    local tool_dir="$1" skill_name="$2"
    local f="$tool_dir/$skill_name/SKILL.md"
    [ -f "$f" ] && echo "$f" && return
    echo ""
}

# ── Write a skill to a tool location ────────────────────────────────────

write_skill() {
    local tool_name="$1" tool_dir="$2" skill_name="$3" source_file="$4"
    local dest_dir="$tool_dir/$skill_name"
    mkdir -p "$dest_dir"

    cp "$source_file" "$dest_dir/SKILL.md"

    # Codex needs agents/openai.yaml
    if [ "$tool_name" = "codex" ]; then
        mkdir -p "$dest_dir/agents"
        local desc
        desc=$(extract_description "$source_file")
        [ -z "$desc" ] && desc="$skill_name"
        cat > "$dest_dir/agents/openai.yaml" <<YAML_EOF
interface:
  display_name: "$skill_name"
  short_description: "${desc:0:64}"
  default_prompt: "Use \$${skill_name} to help with this task."
YAML_EOF
    fi
}

# ── Collect all skill names across all tools ────────────────────────────

collect_all_skills() {
    local all_file="$1"
    local IFS='|'
    for tool_entry in "${TOOLS[@]}"; do
        set -- $tool_entry
        local tool_name="$1" tool_dir="$2"
        for skill_dir in "$tool_dir"/*/; do
            [ -d "$skill_dir" ] || continue
            local name
            name=$(basename "$skill_dir")
            [[ "$name" == .* ]] && continue
            [ -f "$skill_dir/SKILL.md" ] || continue
            echo "$name" >> "$all_file"
        done
    done
    sort -u "$all_file" > "${all_file}.sorted"
    mv "${all_file}.sorted" "$all_file"
}

# ── Sync one skill across all tools ─────────────────────────────────────

sync_skill() {
    local skill_name="$1"
    local IFS='|'

    # Find the newest version across all tools
    local newest_file="" newest_mtime=0 newest_tool="" canonical_file=""
    local any_change=false

    for tool_entry in "${TOOLS[@]}"; do
        set -- $tool_entry
        local tool_name="$1" tool_dir="$2"
        local skill_file
        skill_file=$(find_skill_file "$tool_dir" "$skill_name")
        [ -z "$skill_file" ] && continue

        if [ "$tool_name" = "canonical" ]; then
            canonical_file="$skill_file"
        fi

        local current_hash stored_hash
        current_hash=$(content_hash "$skill_file")
        stored_hash=$(get_hash "${skill_name}_${tool_name}")

        if [ "$current_hash" != "$stored_hash" ]; then
            any_change=true
        fi

        local mtime
        mtime=$(stat -f %m "$skill_file" 2>/dev/null || echo 0)
        if [ "$mtime" -gt "$newest_mtime" ]; then
            newest_mtime="$mtime"
            newest_file="$skill_file"
            newest_tool="$tool_name"
        fi
    done

    if ! $any_change; then
        log "  [OK]       $skill_name"
        return
    fi

    # If no canonical version exists yet, or canonical is not the newest
    if [ -z "$canonical_file" ] || [ "$newest_tool" != "canonical" ]; then
        # Write newest to canonical first
        write_skill "canonical" "$CANONICAL" "$skill_name" "$newest_file"
        canonical_file="$CANONICAL/$skill_name/SKILL.md"
    fi

    # Now sync canonical to all tools that need updating
    local synced_to=""
    for tool_entry in "${TOOLS[@]}"; do
        set -- $tool_entry
        local tool_name="$1" tool_dir="$2"
        [ "$tool_name" = "canonical" ] && continue

        local existing
        existing=$(find_skill_file "$tool_dir" "$skill_name")
        local existing_hash="MISSING"
        [ -n "$existing" ] && existing_hash=$(content_hash "$existing")

        local canonical_hash
        canonical_hash=$(content_hash "$canonical_file")

        if [ "$existing_hash" != "$canonical_hash" ]; then
            write_skill "$tool_name" "$tool_dir" "$skill_name" "$canonical_file"
            synced_to="${synced_to} ${tool_name}"
        fi

        queue_hash "${skill_name}_${tool_name}" "$(content_hash "$tool_dir/$skill_name/SKILL.md")"
    done

    queue_hash "${skill_name}_canonical" "$(content_hash "$canonical_file")"

    if [ -n "$synced_to" ]; then
        local desc
        desc=$(extract_description "$canonical_file")
        SYNCED+=("$skill_name (from $newest_tool ->$synced_to)")
        log "  [SYNC]     $skill_name"
        log "             Source: $newest_tool -> $synced_to"
        log "             Description: ${desc:0:100}"
    fi
}

# ── Commands ────────────────────────────────────────────────────────────

declare_tools

# --status: show what's detected
if [[ "${1:-}" == "--status" ]]; then
    echo "Detected AI CLI tools:"
    echo ""
    IFS='|'
    for tool_entry in "${TOOLS[@]}"; do
        set -- $tool_entry
        tool_name="$1"; tool_dir="$2"
        count=$(find "$tool_dir" -maxdepth 1 -mindepth 1 -type d -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')
        printf "  %-12s %s skills  %s\n" "$tool_name" "$count" "$tool_dir"
    done
    unset IFS
    echo ""
    exit 0
fi

# --seed: import everything into canonical, then push to all tools
if [[ "${1:-}" == "--seed" ]]; then
    > "$SYNC_LOG"
    echo '{}' > "$HASH_STORE"
    > "$HASH_CACHE"
    log "======= SEED MODE: importing all skills ======="

    all_file=$(mktemp)
    collect_all_skills "$all_file"

    skill_count=0
    while IFS= read -r skill_name; do
        [ -z "$skill_name" ] && continue
        sync_skill "$skill_name"
        skill_count=$((skill_count + 1))
    done < "$all_file"
    rm -f "$all_file"

    flush_hashes
    log "Seed complete. $skill_count skills across ${#TOOLS[@]} tools."
    notify "⚡ Skill Sync" "✅ Seeded: $skill_count skills across ${#TOOLS[@]} tools" "file://$SYNC_LOG"
    echo "⚡ Seed complete. $skill_count skills across ${#TOOLS[@]} tools."
    exit 0
fi

# Normal sync
log "========================================================"
log "🔄 Skill Sync Started"
IFS='|'
for tool_entry in "${TOOLS[@]}"; do
    set -- $tool_entry
    count=$(find "$2" -maxdepth 1 -mindepth 1 -type d -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    log "  $1: $count skills ($2)"
done
unset IFS
log "--------------------------------------------------------"

all_skills_file=$(mktemp)
collect_all_skills "$all_skills_file"

while IFS= read -r skill_name; do
    [ -z "$skill_name" ] && continue
    sync_skill "$skill_name"
done < "$all_skills_file"

rm -f "$all_skills_file" "$HASH_CACHE"
flush_hashes

log "--------------------------------------------------------"
log "Result: ${#SYNCED[@]} synced"
for s in "${SYNCED[@]+"${SYNCED[@]}"}"; do
    [ -n "$s" ] && log "  + $s"
done
log "========================================================"
log ""

# Notifications
LOG_URL="file://$SYNC_LOG"
if [ ${#SYNCED[@]} -gt 0 ]; then
    count=${#SYNCED[@]}
    first_name=$(printf '%s\n' "${SYNCED[0]}" | sed 's/ (.*//')
    if [ "$count" -eq 1 ]; then
        notify "🔄 Skill Sync" "✅ Synced: $first_name" "$LOG_URL"
    else
        notify "🔄 Skill Sync" "✅ $count synced: $first_name +$((count - 1)) more" "$LOG_URL"
    fi
    echo "✅ Synced $count skill(s):"
    printf '  🔗 %s\n' "${SYNCED[@]}"
else
    echo "✨ All skills up to date."
fi
