# Copies Claude Code's skills, memory notes and homelab context from mjolnir to
# hermod, where hermes reads them from /var/lib/hermes/claude (see
# hosts/hermod/modules/system/hermes-agent.nix). Kept out of git: the repo is public.
# Run it again after Claude's skills or notes change.
set -euo pipefail

host=christina@10.0.20.21
dest=/var/lib/hermes/claude
mem="$HOME/.claude/projects/-home-christina-nixos-dotfiles/memory"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# Skills, without Claude Code's own synced bucket.
mkdir -p "$stage/skills"
for s in "$HOME"/.claude/skills/*/; do
  name=$(basename "$s")
  [ "$name" = synced ] && continue
  cp -rL "$s" "$stage/skills/$name"
done

# The memory notes as one skill: SKILL.md is the index, the notes are its files.
m="$stage/skills/claude-memory"
mkdir -p "$m/references"
cp "$mem"/*.md "$m/references/"
rm -f "$m/references/MEMORY.md"
{
  cat <<'EOF'
---
name: claude-memory
description: Notes Claude Code saved while working with Christina on mjolnir. Her Blender and Octane characters, rigs, outfits and scenes, what she likes and how she wants work done, and homelab and fleet facts. Load it before Blender, Octane, character, scene or fleet work, then read the notes that match.
---

# Claude's memory notes

Each line names one note in `references/`. Read the ones that match the task with
skill_view (file_path `references/<file>.md`). They reflect what was true when they
were written: check a file, object or setting still exists before relying on it.
Feedback notes say what she corrected and why; follow them.

EOF
  grep '^- \[' "$mem/MEMORY.md" | sed -E 's/\]\(([^)]+\.md)\)/](references\/\1)/'
} > "$m/SKILL.md"

# Homelab context, with what differs on hermod first.
{
  cat <<'EOF'
# Context for hermes on hermod

Copied from Claude Code's context on mjolnir by `claude-to-hermod`. The part after the
line was written for Claude Code on mjolnir; read it with these differences:

- You run on hermod (10.0.20.21) as the user hermes, not on mjolnir; the gateway and
  Christina's `hermes` CLI both do. The vault is at /mnt/muninn (not ~/muninn).
  Read /mnt/muninn/CLAUDE.md first: it holds the vault conventions.
- Query the vault and the nixos-dotfiles repo with the graphify-vault and
  graphify-dotfiles MCP tools (they run on heimdall over SSH), or read notes directly.
- File a report by writing one Markdown note into the vault's _inbox/ folder, mode 0644,
  and never touch it again after it lands (huginn files it within a minute; a change
  while it reads fails the sweep). Frontmatter with `agent: hermes`, a
  `# <topic> — report YYYY-MM-DD` title, what was found, what changed, what is open.
  Over 2,000 characters, wikilinks to real notes by their exact name, and never start
  the body with `todo:` or `jev:` (that turns it into a request).
- Blender: the `blender` MCP server runs on mjolnir over SSH and drives the Blender Lab
  MCP extension there. Blender must be open on mjolnir, or its tools fail.
- Your skills include `claude-memory`: Claude's notes from its sessions with Christina.
  Load it before Blender or fleet work.

---

EOF
  cat "$HOME/.claude/CLAUDE.md"
} > "$stage/AGENTS.md"

# hermod has no rsync: unpack into a fresh folder, then swap it in.
tar -C "$stage" -cf - skills AGENTS.md | ssh -o BatchMode=yes "$host" "
  set -e
  umask 007
  rm -rf $dest/.incoming
  mkdir $dest/.incoming
  tar -C $dest/.incoming --no-same-permissions -xf -
  rm -rf $dest/skills
  mv $dest/.incoming/skills $dest/skills
  cp $dest/.incoming/AGENTS.md /var/lib/hermes/workspace/AGENTS.md
  rm -rf $dest/.incoming
"
echo "copied $(find "$stage/skills" -maxdepth 1 -mindepth 1 | wc -l) skills ($(find "$m/references" -name '*.md' | wc -l) memory notes in claude-memory) and AGENTS.md to hermod"
