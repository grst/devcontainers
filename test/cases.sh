#!/usr/bin/env bash
# The negative cases: a gate that stops refusing, or an isolation check that stops
# noticing, fails silently in a way that only shows up when it matters. Each case
# starts a container with deliberately wrong flags and asserts the check's exit code.
#
#   bash test/cases.sh dc-python:test
#   ENGINE=podman bash test/cases.sh dc-python:test
#
# Run by test.yaml, and runnable by hand against a locally built image. Defaults to
# docker because that is what the runners have and nothing here is podman-specific;
# the podman-only parts (up.sh, --userns=keep-id) are exercised on the host, see the
# README.
set -uo pipefail

IMAGE="${1:?usage: cases.sh <image>}"
ENGINE="${ENGINE:-docker}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${REPO}/test/python:/workspace"

pass=0 fail=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# run_case <ok|refuse> <firewall|isolation> <description> [docker run flags...]
#
# "refuse" means the check must exit non-zero, which is what takes `devcontainer up`
# down with it.
run_case() {
    local expect="$1" check="$2" desc="$3" got
    shift 3

    if "$ENGINE" run --rm "$@" "$IMAGE" \
        sudo -E "/usr/local/bin/devcontainer-${check}" >"$log" 2>&1
    then got=ok; else got=refuse; fi

    if [ "$got" = "$expect" ]; then
        printf '  \033[32mok\033[0m    %s\n' "$desc"
        pass=$(( pass + 1 ))
    else
        printf '  \033[31mFAIL\033[0m  %s (expected %s, got %s)\n' "$desc" "$expect" "$got"
        sed 's/^/        | /' "$log"
        fail=$(( fail + 1 ))
    fi
}

echo
echo '== the firewall gate must fail the container, not just complain =='
run_case refuse firewall 'unset DEVCONTAINER_FIREWALL is refused'
run_case refuse firewall 'firewall=on without NET_ADMIN is refused' \
    -e DEVCONTAINER_FIREWALL=on

echo
echo '== the isolation check must notice the things it exists for =='
run_case refuse isolation 'an unexpected writable bind mount' \
    -v "$WORKSPACE" -v "${REPO}/test:/mnt/host-escape"
run_case ok     isolation 'a declared read-only mount is accepted' \
    -e DEVCONTAINER_EXTRA_MOUNTS=/mnt/models:ro \
    -v "$WORKSPACE" -v "${REPO}/test:/mnt/models:ro"
run_case refuse isolation 'a mount declared ro but mounted rw' \
    -e DEVCONTAINER_EXTRA_MOUNTS=/mnt/models:ro \
    -v "$WORKSPACE" -v "${REPO}/test:/mnt/models"
# A forwarded agent is a signing oracle for every host that trusts the key, so its
# blast radius reaches machines the container boundary does not cover at all.
run_case refuse isolation 'a forwarded SSH agent' \
    -e SSH_AUTH_SOCK=/tmp/agent.sock -v "$WORKSPACE"
# With a runtime socket an agent can start a privileged container and write anywhere
# on the host -- a container escape, and the worst of these by some margin.
run_case refuse isolation 'a mounted container runtime socket' \
    -v "$WORKSPACE" -v /var/run/docker.sock:/var/run/docker.sock

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
