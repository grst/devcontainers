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
#   3. keepassxc-cli against the database, which prompts for the master password once
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

# ---------------------------------------------------------------------------
# Layer 2 availability: is anything actually serving org.freedesktop.secrets?
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Layer 3 database: whatever KeePassXC itself would open
# ---------------------------------------------------------------------------
# Discovered rather than required. This used to insist on $KEEPASSXC_DB and skip the
# whole layer when it was unset -- which is why no password prompt ever appeared: the
# only prompting path was silently unreachable.
#
# KeePassXC 2.7+ keeps the remembered databases in the *cache* config, not the one
# under ~/.config, so read that.
discover_db() {
    if [ -n "${KEEPASSXC_DB:-}" ]; then
        printf '%s' "$KEEPASSXC_DB"
        return 0
    fi

    local ini="${XDG_CACHE_HOME:-$HOME/.cache}/keepassxc/keepassxc.ini" db=''
    [ -r "$ini" ] || return 1

    db="$(sed -n 's/^LastActiveDatabase=//p' "$ini" | head -1)"
    # LastOpenedDatabases/LastDatabases are comma-separated, most recent first.
    [ -n "$db" ] || db="$(sed -n 's/^LastOpenedDatabases=//p' "$ini" | head -1 | cut -d, -f1)"
    [ -n "$db" ] || db="$(sed -n 's/^LastDatabases=//p' "$ini" | head -1 | cut -d, -f1)"

    db="${db#"${db%%[![:space:]]*}"}"    # trim leading whitespace
    db="${db%"${db##*[![:space:]]}"}"    # trim trailing whitespace
    [ -n "$db" ] && [ -f "$db" ] || return 1
    printf '%s' "$db"
}

# The master password is read once and reused for every entry, so a run needing the cli
# for both secrets prompts once rather than twice. Read from /dev/tty, not stdin: up.sh
# calls this in a command substitution, so stdin may not be the terminal.
#
# Openability, not `[ -r /dev/tty ]`: /dev/tty is mode 0666, so the -r test passes even
# with no controlling terminal at all (a VS Code lifecycle hook, cron, a CI runner) and
# the prompt would then fail in a way that looks like a wrong password.
tty_available() { (exec 3< /dev/tty) 2>/dev/null; }

DB=''
DB_PASSWORD=''
db_password() {
    [ -n "$DB_PASSWORD" ] && { printf '%s' "$DB_PASSWORD"; return 0; }
    tty_available || return 1
    printf 'host-secrets: master password for %s: ' "$DB" > /dev/tty
    IFS= read -rs DB_PASSWORD < /dev/tty
    printf '\n' > /dev/tty
    [ -n "$DB_PASSWORD" ] || return 1
    printf '%s' "$DB_PASSWORD"
}

# keepassxc-cli reads the password from stdin when stdin is not a terminal, which is
# what lets one prompt serve several lookups. -q keeps its own prompts quiet, -s
# reveals Password, which KeePassXC treats as protected.
kp_show() { # kp_show <entry-path>
    local pw
    pw="$(db_password)" || return 2
    keepassxc-cli show -q -s -a Password "$DB" "$1" 2>/dev/null <<<"$pw"
}

# `show` wants the entry's *path*, so an entry inside a group is "Group/Title" and a
# bare title misses it. Ask the database where the title lives before giving up.
kp_locate() { # kp_locate <title>
    local pw
    pw="$(db_password)" || return 2
    keepassxc-cli locate -q "$DB" "$1" 2>/dev/null <<<"$pw"
}

SERVICE_UP=false
secret_service_up && SERVICE_UP=true
DB="$(discover_db || true)"

# ---------------------------------------------------------------------------
# Resolve
# ---------------------------------------------------------------------------
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

    if [ -n "$DB" ] && command -v keepassxc-cli >/dev/null 2>&1; then
        local path="$entry" found=''
        if ! value="$(kp_show "$path")" || [ -z "$value" ]; then
            found="$(kp_locate "$entry" | head -1)"
            if [ -n "$found" ]; then
                path="$found"
                value="$(kp_show "$path")"
            fi
        fi
        if [ -n "$value" ]; then
            printf '%s=%s\n' "$var" "$value"
            log "${var}: from ${DB} (entry \"${path}\")"
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

# ---------------------------------------------------------------------------
# Report which layer was unavailable, and how to fix it
# ---------------------------------------------------------------------------
{
    echo
    echo 'host-secrets.sh: could not resolve:'
    for m in "${missing[@]}"; do
        printf '  - %-20s KeePassXC entry "%s"\n' "${m%%|*}" "${m#*|}"
    done
    echo
    echo 'State of each lookup layer:'

    if [ "$SERVICE_UP" = true ]; then
        echo '  Secret Service   available, but no exposed entry has that title'
        echo '                   check: secret-tool lookup Title "<entry title>" | wc -c'
    elif ! command -v dbus-send >/dev/null 2>&1; then
        echo '  Secret Service   cannot probe: dbus-send is not installed'
    else
        echo '  Secret Service   NOT available -- nobody owns org.freedesktop.secrets on'
        printf '                   %s\n' "${DBUS_SESSION_BUS_ADDRESS:-<no DBUS_SESSION_BUS_ADDRESS>}"
        echo '                   Start KeePassXC and unlock the database, with Settings ->'
        echo '                   Secret Service Integration enabled and the entries group'
        echo '                   exposed. The service lives on whichever session bus'
        echo '                   KeePassXC was started on.'
    fi

    if ! command -v keepassxc-cli >/dev/null 2>&1; then
        echo '  keepassxc-cli    not installed'
    elif [ -z "$DB" ]; then
        echo '  keepassxc-cli    no database found. Set KEEPASSXC_DB=/path/to/db.kdbx, or'
        echo '                   open the database in KeePassXC once so it gets remembered in'
        printf '                   %s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/keepassxc/keepassxc.ini"
    elif ! tty_available; then
        printf '  keepassxc-cli    %s found, but there is no terminal to prompt on.\n' "$DB"
        echo '                   This is the VS Code path: export the variables in the shell'
        echo '                   you launch `code` from, or start the container with up.sh.'
    else
        printf '  keepassxc-cli    %s opened, but no entry there has that title\n' "$DB"
        printf '                   check: keepassxc-cli locate %s "<entry title>"\n' "$DB"
        echo '                   then set ANTHROPIC_KEY_ENTRY / GH_TOKEN_ENTRY to match'
    fi

    echo
    echo 'Or export the variables yourself, or start without them:'
    echo '  DEVCONTAINER_SKIP_SECRETS=1 .devcontainer/up.sh'
} >&2

exit 1
