#!/usr/bin/env bash
# Print `NAME=value` lines for the secrets the container should receive, resolved on
# the host. Used by up.sh; run it on its own to check what would be passed:
#
#   bash .devcontainer/host-secrets.sh >/dev/null    # values hidden, diagnosis shown
#
# Nothing sensitive is ever mounted into the container, so every credential arrives as
# an environment variable through remoteEnv. Each one is resolved in this order:
#
#   1. the variable, if already exported and non-empty
#   2. the Secret Service -- KeePassXC's FdoSecrets integration, which needs no master
#      password while the database is unlocked
#
# Failure is loud and fatal. An earlier version swallowed every error, so a stopped
# KeePassXC, a wrong entry title and a missing exec bit all looked identical to
# "everything is fine" -- right up until Claude Code turned out not to be logged in
# inside the container. If a secret cannot be resolved this exits non-zero and up.sh
# refuses to start the container. To start one deliberately without secrets:
#
#   DEVCONTAINER_SKIP_SECRETS=1 .devcontainer/up.sh
#
# KeePassXC setup, once: Settings -> Secret Service Integration -> Enable, then
# "Manage exposed database groups" and tick the group holding these entries. Exposing
# one group rather than the whole database keeps the blast radius small, since every
# app on your session bus can read what is exposed. Lookups are by entry *title*; the
# group only decides what is visible at all.
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
# credential lands in the container's own volume, not on the host, and disappears with
# the volumes -- so write access is an explicit act per container instead of an ambient
# capability every session inherits.
declare -A SECRETS=(
    [ANTHROPIC_API_KEY]="${ANTHROPIC_KEY_ENTRY:-Anthropic API key}"
    [GH_TOKEN]="${GH_TOKEN_ENTRY:-GitHub read-only token (devcontainer)}"
)

# stdout carries NAME=value and nothing else; all human output goes to stderr.
log() { printf 'host-secrets: %s\n' "$*" >&2; }

# Probed once, up front, so "KeePassXC is not running" gets reported as itself instead
# of as a failed lookup. ListNames rather than ListActivatableNames on purpose:
# KeePassXC ships no D-Bus service file, so it cannot be activated on demand -- if the
# name is not owned right now, there is nobody to ask.
secret_service_up() {
    command -v dbus-send >/dev/null 2>&1 || return 1
    dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null \
        | grep -q '"org.freedesktop.secrets"'
}

SERVICE_UP=false
secret_service_up && SERVICE_UP=true

missing=()
resolve() { # resolve <var> <entry-title>
    local var="$1" entry="$2" value=''

    value="${!var:-}"
    if [ -n "$value" ]; then
        printf '%s=%s\n' "$var" "$value"
        log "${var}: already set in the environment"
        return 0
    fi

    if [ "$SERVICE_UP" = true ] && command -v secret-tool >/dev/null 2>&1; then
        if value="$(secret-tool lookup Title "$entry" 2>/dev/null)" && [ -n "$value" ]; then
            printf '%s=%s\n' "$var" "$value"
            log "${var}: from the Secret Service (entry \"${entry}\")"
            return 0
        fi
    fi

    missing+=("${var}|${entry}")
    return 1
}

for var in "${!SECRETS[@]}"; do
    resolve "$var" "${SECRETS[$var]}" || true
done

[ "${#missing[@]}" -eq 0 ] && exit 0

{
    echo
    echo 'host-secrets.sh: could not resolve:'
    for m in "${missing[@]}"; do
        printf '  - %-20s KeePassXC entry "%s"\n' "${m%%|*}" "${m#*|}"
    done
    echo
    if [ "$SERVICE_UP" = true ]; then
        echo 'The Secret Service is up, but no exposed entry has that title. Check with'
        echo '  secret-tool lookup Title "<entry title>" | wc -c'
        echo 'then set ANTHROPIC_KEY_ENTRY / GH_TOKEN_ENTRY to the titles you actually use.'
    elif ! command -v dbus-send >/dev/null 2>&1; then
        echo 'Cannot probe the Secret Service: dbus-send is not installed.'
    else
        printf 'Nobody owns org.freedesktop.secrets on %s.\n' \
            "${DBUS_SESSION_BUS_ADDRESS:-<no DBUS_SESSION_BUS_ADDRESS>}"
        echo 'Start KeePassXC and unlock the database, with Settings -> Secret Service'
        echo 'Integration enabled and the entries group exposed. The service lives on'
        echo 'whichever session bus KeePassXC was started on.'
    fi
    echo
    echo 'Or export the variables yourself, or start without them:'
    echo '  DEVCONTAINER_SKIP_SECRETS=1 .devcontainer/up.sh'
} >&2

exit 1
