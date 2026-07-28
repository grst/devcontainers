#!/usr/bin/env bash
# Runs once after the container is created, and is safe to re-run by hand at any
# time (e.g. after adding a pyproject.toml).
#
# Its main job is to make Claude Code start straight into auto mode with nothing to
# click. That configuration lives in the container's CLAUDE_CONFIG_DIR volume,
# never in the repository, so it cannot leak into a Claude Code run on the host.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"

# write_json <file> <jq filter> [jq args...]
# Merges into the file rather than replacing it, so re-running is idempotent and
# hand edits survive.
write_json() {
    local file="$1" filter="$2"
    shift 2
    [ -f "$file" ] || printf '{}\n' > "$file"
    local tmp
    tmp="$(mktemp)"
    jq "$@" "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
}

echo '==> Configuring Claude Code for auto mode'
# defaultMode "auto" is only honoured from *user* settings -- Claude Code ignores
# it in a repo's .claude/settings.json so a repository cannot grant itself auto
# mode. $CLAUDE_CONFIG_DIR is user scope inside the container, so writing it here
# works and affects nothing on the host.
#
# The status line is the copy baked into the image, not one vendored per repo.
write_json "$CLAUDE_DIR/settings.json" \
    '.permissions = ((.permissions // {}) + {defaultMode: "auto"})
     | .statusLine = {type: "command", command: "sh /usr/local/share/devcontainer/statusline.sh"}'

# Skip the first-run onboarding and folder-trust prompts. These are internal config
# keys of the CLI rather than a documented API, so treat them as best effort: if a
# release renames one you just get the prompt back.
write_json "$CLAUDE_DIR/.claude.json" \
    '.hasCompletedOnboarding = true
     | .projects = ((.projects // {}) | .[$ws] = ((.[$ws] // {}) + {hasTrustDialogAccepted: true}))' \
    --arg ws "${PWD}"

# Pre-approve the API key, matched by its last 20 characters, which is how the CLI
# records the approval -- otherwise the first launch asks about it.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    write_json "$CLAUDE_DIR/.claude.json" \
        '.customApiKeyResponses = ((.customApiKeyResponses // {})
            | .approved = (((.approved // []) + [$k]) | unique)
            | .rejected = (.rejected // []))' \
        --arg k "${ANTHROPIC_API_KEY: -20}"
    echo '    ANTHROPIC_API_KEY found and pre-approved'
else
    echo "    No ANTHROPIC_API_KEY; run 'claude' once and log in (persists in the volume)"
fi

# ---------------------------------------------------------------------------
# peon-ping
# ---------------------------------------------------------------------------
# Hooks run inside the container; sound and desktop notifications happen on the
# host through the relay. Every event is async except SessionStart, so hooks never
# block the session.
if [ "${DEVCONTAINER_PEON:-off}" = 'on' ] && [ -x "${CLAUDE_PEON_DIR:-/nonexistent}/peon.sh" ]; then
    echo '==> Wiring peon-ping hooks to the host relay'
    write_json "$CLAUDE_DIR/settings.json" \
        '(.hooks // {}) as $existing
         | ([{matcher: "", hooks: [{type: "command", command: $peon, timeout: 10}]}]) as $sync
         | ([{matcher: "", hooks: [{type: "command", command: $peon, timeout: 10, async: true}]}]) as $async
         | .hooks = ($existing
             + {SessionStart: $sync}
             + ($events | split(",") | map({key: ., value: $async}) | from_entries))' \
        --arg peon "${CLAUDE_PEON_DIR}/peon.sh" \
        --arg events "SessionEnd,SubagentStart,SubagentStop,UserPromptSubmit,Stop,Notification,PermissionRequest,PreToolUse,PostToolUseFailure,PreCompact"

    # The relay lives on the host's loopback, reachable via pasta's mapped address.
    # Without this fragment, firewall=on blocks the bridge.
    echo '169.254.1.2   # peon-ping relay on the host loopback (via pasta map-host-loopback)' \
        | sudo tee /etc/devcontainer/firewall-allowlist.d/10-peon.txt >/dev/null
elif [ "${DEVCONTAINER_PEON:-off}" = 'on' ]; then
    echo '==> peonPing=on but /opt/peon-ping/peon.sh is not executable; skipping hooks'
    sudo rm -f /etc/devcontainer/firewall-allowlist.d/10-peon.txt
else
    echo '==> peon-ping disabled (peonPing=off)'
    sudo rm -f /etc/devcontainer/firewall-allowlist.d/10-peon.txt
fi

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------
# No `git config --global` anywhere in this script: safe.directory is baked into
# /etc/gitconfig in the image, and creating a ~/.gitconfig here would shadow it.
echo '==> Setting up the Python environment'
if [ -f pyproject.toml ]; then
    # --all-groups so dev/test dependency groups are present, which is what an
    # agent needs to actually run the test suite.
    if uv sync --all-groups; then
        echo "    .venv ready ($(uv run python -V 2>/dev/null))"
    else
        echo '    uv sync failed; fix pyproject.toml and re-run this script'
    fi
elif [ -f requirements.txt ]; then
    uv venv && uv pip install -r requirements.txt
else
    echo '    No pyproject.toml yet; creating a bare venv'
    uv venv
fi

if [ -f .pre-commit-config.yaml ] && [ -d .git ]; then
    echo '==> Installing pre-commit hooks (via prek)'
    prek install --install-hooks
fi

echo '==> Done. Start Claude Code with: claude'
