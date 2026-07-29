#!/usr/bin/env bash
# Build/start the dev container with rootless podman and drop into a shell.
#
#   .devcontainer/up.sh                              # start (or reuse), open zsh
#   .devcontainer/up.sh --remove-existing-container  # rebuild
#   .devcontainer/up.sh --build-no-cache --remove-existing-container
#
# Any extra arguments are forwarded to `devcontainer up`. Idempotent: run it again
# from another terminal to get a second shell in the same container.
#
# Podman only. See the README for the host prerequisites (the overlay kernel module
# and the D-Bus session gotcha below).
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Secrets, before anything touches D-Bus
# ---------------------------------------------------------------------------
# Order matters. KeePassXC owns org.freedesktop.secrets on whichever session bus it
# was started on -- typically the dbus-launch bus, not the systemd user bus. Asking
# the systemd user bus instead makes D-Bus try to activate a *second* KeePassXC and
# time out. So fetch the secrets while we still have the inherited bus, and only
# then repoint DBUS_SESSION_BUS_ADDRESS for podman below.
if [ "${DEVCONTAINER_SKIP_SECRETS:-0}" = 1 ]; then
    echo 'up.sh: DEVCONTAINER_SKIP_SECRETS=1 -- starting with no secrets' >&2
else
    # Invoked through `bash`, and tested with -r rather than -x. `devcontainer
    # templates apply` copies these files with whatever mode they had in the template,
    # and an `[ -x ]` guard here silently turned the entire block into a no-op when the
    # exec bit was missing: no lookup, no password prompt, no error, and a container
    # where Claude Code simply was not logged in.
    if [ ! -r .devcontainer/host-secrets.sh ]; then
        echo 'up.sh: .devcontainer/host-secrets.sh is missing -- re-apply the template' >&2
        exit 1
    fi

    # Command substitution, not process substitution: `while read < <(cmd)` discards
    # cmd's exit status, so a failed fetch was indistinguishable from an empty one.
    # Keeping the values in a variable also avoids putting them in a temporary file.
    if ! secrets="$(bash .devcontainer/host-secrets.sh)"; then
        echo 'up.sh: refusing to start the container without its secrets (see above)' >&2
        exit 1
    fi
    while IFS='=' read -r name value; do
        [ -n "$name" ] || continue
        export "${name}=${value}"
    done <<<"$secrets"
    unset secrets
fi

# ---------------------------------------------------------------------------
# D-Bus
# ---------------------------------------------------------------------------
# crun asks the session bus for org.freedesktop.systemd1 when it creates the
# container's cgroup scope. On sessions where DBUS_SESSION_BUS_ADDRESS points at a
# plain dbus-daemon bus (dbus-launch / startx setups) rather than the systemd user
# bus, that call fails with "sd-bus call: ... Input/output error", so prefer the
# systemd user bus whenever its socket exists.
_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -S "${_runtime_dir}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${_runtime_dir}/bus"
fi

# ---------------------------------------------------------------------------
# peon-ping relay
# ---------------------------------------------------------------------------
# Hooks run inside the container but audio and notifications happen on the host, so
# the relay has to be up. The bind source itself is created by initializeCommand in
# devcontainer.json, which runs for VS Code too.
PEON_HOST_DIR="${PEON_HOST_DIR:-$HOME/.claude/hooks/peon-ping}"
if [ -x "${PEON_HOST_DIR}/relay.sh" ] \
    && ! "${PEON_HOST_DIR}/relay.sh" --status >/dev/null 2>&1; then
    "${PEON_HOST_DIR}/relay.sh" --daemon >/dev/null 2>&1 \
        || echo 'up.sh: could not start the peon-ping relay' >&2
fi

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
if command -v devcontainer >/dev/null 2>&1; then
    CLI=(devcontainer)
else
    CLI=(npx -y @devcontainers/cli@latest)
fi

# --docker-path has no environment variable or config file equivalent, so it is
# passed on every invocation; without it the CLI looks for a `docker` binary.
PODMAN=(--docker-path podman)

"${CLI[@]}" up --workspace-folder . "${PODMAN[@]}" "$@"
exec "${CLI[@]}" exec --workspace-folder . "${PODMAN[@]}" zsh
