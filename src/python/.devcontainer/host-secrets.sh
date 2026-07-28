#!/usr/bin/env bash
# Print `NAME=value` lines for the secrets the container should receive, resolved on
# the host. Sourced by up.sh; usable on its own to check what would be passed.
#
# Nothing sensitive is ever mounted into the container, so every credential arrives
# as an environment variable through remoteEnv. Each one is resolved in this order:
#
#   1. the variable, if already exported
#   2. the Secret Service -- i.e. KeePassXC's FdoSecrets integration, which needs no
#      master password prompt while the database is unlocked
#   3. keepassxc-cli against $KEEPASSXC_DB, which does prompt
#
# A secret that cannot be resolved is simply omitted; the container then falls back
# (Claude Code to its stored login, gh to unauthenticated access). Missing secrets
# are never fatal.
#
# KeePassXC setup, once: Settings -> Secret Service Integration -> Enable, then
# "Manage exposed database groups" and tick the group holding these entries.
# Exposing one group rather than the whole database keeps the blast radius small,
# since every app on your session bus can read what is exposed. Lookups are by
# entry *title*; the group only decides what is visible at all.
#
# Verify without revealing anything:
#   secret-tool lookup Title "Anthropic API key" | wc -c    # non-zero = works
set -uo pipefail

# ---------------------------------------------------------------------------
# What to fetch: ENV_VAR=KeePassXC entry title
# ---------------------------------------------------------------------------
# Override a title per machine from your shell rc, e.g.
#   export ANTHROPIC_KEY_ENTRY="Anthropic scverse API key"
#
# GH_TOKEN must be a READ-ONLY token, and that is a design decision rather than a
# limitation. It covers what an agent needs constantly -- clone, `gh api`, reading
# issues, PRs and CI logs -- with no host credential mounted, and because it cannot
# write, an agent running in auto mode that holds it cannot push, open PRs or change
# anything on GitHub. If it leaks, the damage is "someone can read what you can
# read", which is a very different problem from a leaked write token.
#
# When you actually want to push, run `gh auth login` inside the container. That
# credential lands in the container's own volume, not on the host, and disappears
# with the volumes -- so write access is an explicit act per container instead of an
# ambient capability every session inherits.
declare -A SECRETS=(
    [ANTHROPIC_API_KEY]="${ANTHROPIC_KEY_ENTRY:-Anthropic API key}"
    [GH_TOKEN]="${GH_TOKEN_ENTRY:-GitHub read-only token (devcontainer)}"
)

lookup() {
    local var="$1" entry="$2" value=''

    # 1. Already in the environment.
    value="${!var:-}"
    if [ -n "$value" ]; then
        printf '%s=%s\n' "$var" "$value"
        return 0
    fi

    # 2. Secret Service (KeePassXC FdoSecrets).
    if command -v secret-tool >/dev/null 2>&1; then
        if value="$(secret-tool lookup Title "$entry" 2>/dev/null)" && [ -n "$value" ]; then
            printf '%s=%s\n' "$var" "$value"
            return 0
        fi
    fi

    # 3. keepassxc-cli. -q keeps prompts off stdout, -s reveals the protected
    #    Password attribute.
    if [ -n "${KEEPASSXC_DB:-}" ] && command -v keepassxc-cli >/dev/null 2>&1; then
        if value="$(keepassxc-cli show -q -s -a Password "$KEEPASSXC_DB" "$entry" 2>/dev/null)" \
            && [ -n "$value" ]; then
            printf '%s=%s\n' "$var" "$value"
            return 0
        fi
    fi

    echo "host-secrets.sh: ${var} not found (KeePassXC entry \"${entry}\")" >&2
    return 1
}

status=0
for var in "${!SECRETS[@]}"; do
    lookup "$var" "${SECRETS[$var]}" || status=1
done

# Non-zero only tells the caller that something was missing; up.sh treats that as a
# warning, not an error.
exit "$status"
