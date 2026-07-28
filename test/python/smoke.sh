#!/usr/bin/env bash
# Smoke test, run inside a built container.
#
#   podman run --rm -v "$PWD/test/python:/workspace:ro" <image> bash /workspace/smoke.sh
#
# or, against a running dev container:
#
#   devcontainer exec --workspace-folder test/python --docker-path podman bash smoke.sh
#
# Checks the things that silently rot: a tool that vanished from the archive, a
# dotfile that stopped parsing, a firewall gate that stopped gating. Does not need
# the network, except for the two firewall behaviour checks which are skipped when
# the firewall is off.
set -uo pipefail

pass=0 fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$(( fail + 1 )); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$1"; }

check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

echo
echo '== tools on PATH =='
for tool in zsh git gh jq yq fzf fd rg rga bat delta mlr tree nvim tmux direnv \
            node npm claude ipset iptables dig \
            uv uvx python ruff prek pre-commit hatch ipython zizmor cruft chromium; do
    check "$tool" command -v "$tool"
done

echo
echo '== versions that must be new enough =='
# fzf --zsh needs >= 0.48; the zsh config relies on it instead of vendoring
# keybinding files.
check 'fzf supports --zsh' fzf --zsh
# Python 3.14 is the documented default for a project that pins nothing.
py_version="$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
if [ "$py_version" = '3.14' ]; then
    ok "python is 3.14 (got ${py_version})"
else
    bad "python should be 3.14, got '${py_version}'"
fi
if uv python list 2>/dev/null | grep -q 'cpython-3\.13'; then
    ok '3.13 is preinstalled for matrix work'
else
    bad '3.13 is not preinstalled'
fi

echo
echo '== shell configuration =='
check 'interactive zsh loads cleanly' zsh -ic 'true'
# The whole point of the fzf block: ^R must be fzf's widget, not zsh's builtin
# history search, which means fzf has to be sourced after the base keybindings.
if zsh -ic 'bindkey "^R"' 2>/dev/null | grep -q 'fzf-history-widget'; then
    ok 'Ctrl+R is bound to fzf-history-widget'
else
    bad "Ctrl+R is not fzf's history widget: $(zsh -ic 'bindkey "^R"' 2>&1 | tail -1)"
fi
if zsh -ic 'bindkey "^T"' 2>/dev/null | grep -q 'fzf-file-widget'; then
    ok 'Ctrl+T is bound to fzf-file-widget'
else
    bad 'Ctrl+T is not fzf-file-widget'
fi
check 'vi mode is active' bash -c '[ -n "$(zsh -ic "bindkey -lL main" 2>/dev/null | grep viins)" ]'
check 'aliases are loaded (ll)' zsh -ic 'alias ll'
check 'aliases are loaded (st)' zsh -ic 'alias st'
check 'functions are loaded (c)' zsh -ic 'declare -f c'
# These must NOT be interactive: cp -i blocks on stdin and hangs agents.
if zsh -ic 'alias cp' >/dev/null 2>&1; then
    bad 'cp is aliased -- it must stay unaliased so it never prompts'
else
    ok 'cp is not aliased'
fi
check 'history goes to the volume' bash -c '[ "$(zsh -ic "echo \$HISTFILE")" = /commandhistory/.zsh_history ]'

echo
echo '== git configuration =='
check 'system gitconfig is present' test -r /etc/gitconfig
check 'delta is the pager' bash -c '[ "$(git config --get core.pager)" = delta ]'
# The GIT_CONFIG_* override in devcontainer.json must win over any gitconfig.
if [ "$(git config --get commit.gpgsign)" = 'false' ]; then
    ok 'commit signing is off (no key is mounted, so signing would fail)'
else
    bad "commit.gpgsign should be false, got '$(git config --get commit.gpgsign)'"
fi
check 'no ~/.gitconfig shadowing the system one' bash -c '[ ! -f "$HOME/.gitconfig" ]'

echo
echo '== isolation =='
# Guarantee 1: nothing writable but the workspace.
# fuse.fuse-overlayfs alongside overlay: rootless podman uses it for the container's
# own root filesystem when the kernel overlay driver is unavailable, and without it the
# list below reports / as an unexpected writable mount.
writable_binds="$(awk '$0 !~ / - (overlay|fuse\.fuse-overlayfs|proc|sysfs|devpts|mqueue|tmpfs|devtmpfs|cgroup|cgroup2|securityfs|bpf|tracefs|debugfs|configfs|fusectl|pstore|nsfs|binfmt_misc|hugetlbfs|autofs) / && $6 ~ /^rw/ {print $5}' \
    /proc/self/mountinfo | grep -Ev '^(/proc|/sys|/dev)' | sort)"
echo "        writable non-pseudo mounts: $(echo "$writable_binds" | tr '\n' ' ')"
# Mounted rw *and* actually writable by this user -- the mount flag alone says nothing
# about ownership, and a workspace owned by a uid this container cannot map surfaces
# far downstream as a mystery `uv sync` failure instead of an isolation-check failure.
if [ -z "$(echo "$writable_binds" | grep -Fx /workspace)" ]; then
    bad '/workspace is not mounted read-write'
elif touch /workspace/.write-probe 2>/dev/null; then
    rm -f /workspace/.write-probe
    ok '/workspace is writable'
else
    bad "/workspace is mounted rw but not writable by $(id -un) -- it is owned by uid $(stat -c %u /workspace)"
fi
check 'no container runtime socket' bash -c '! ls /var/run/docker.sock /run/docker.sock /run/podman/podman.sock 2>/dev/null | grep -q .'
check 'no forwarded ssh agent' bash -c '[ -z "${SSH_AUTH_SOCK:-}" ]'
check 'no host ssh keys' bash -c '[ -z "$(ls -A "$HOME/.ssh" 2>/dev/null)" ]'
check 'no host gnupg' bash -c '[ -z "$(ls -A "$HOME/.gnupg" 2>/dev/null)" ]'
check 'host home is not reachable' bash -c '! ls /home/sturm 2>/dev/null'
if [ -e /opt/peon-ping ]; then
    if touch /opt/peon-ping/.write-probe 2>/dev/null; then
        rm -f /opt/peon-ping/.write-probe
        bad '/opt/peon-ping is writable -- it must be mounted readonly'
    else
        ok '/opt/peon-ping is read-only'
    fi
else
    skip '/opt/peon-ping is not mounted'
fi
check 'the isolation check itself passes' sudo /usr/local/bin/devcontainer-isolation

echo
echo '== firewall gate =='
# The gate must refuse an unset or bogus value. This is the check that keeps
# "did I remember to choose?" from being answerable by accident.
if sudo DEVCONTAINER_FIREWALL= /usr/local/bin/devcontainer-firewall >/dev/null 2>&1; then
    bad 'an empty DEVCONTAINER_FIREWALL was accepted -- the gate is not gating'
else
    ok 'empty DEVCONTAINER_FIREWALL is refused'
fi
if sudo DEVCONTAINER_FIREWALL=maybe /usr/local/bin/devcontainer-firewall >/dev/null 2>&1; then
    bad 'an invalid DEVCONTAINER_FIREWALL was accepted'
else
    ok 'invalid DEVCONTAINER_FIREWALL is refused'
fi
check 'the base allowlist is installed' test -r /etc/devcontainer/firewall-allowlist.d/00-base.txt

echo
echo '== firewall behaviour =='
fw_state="$(cat /run/devcontainer/firewall.state 2>/dev/null || echo unset)"
echo "        firewall.state = ${fw_state}"
case "$fw_state" in
    on)
        # HEAD, not GET. https://pypi.org/simple/ is the full index -- 44 MB -- so a
        # GET with any sane --max-time reports a timeout that looks exactly like the
        # host being blocked. This probe is about reachability, so ask for headers.
        if curl -fsS -I --max-time 10 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
            ok 'an allowlisted host (pypi.org) is reachable'
        else
            bad 'an allowlisted host (pypi.org) is NOT reachable'
        fi
        # Checked per family, not just with the default selection. An IPv4-only
        # ruleset on a dual-stack container passes the plain check while leaving
        # everything reachable over v6 -- that is a hole this repo actually shipped
        # once, so it gets its own assertions.
        for fam in '' -4 -6; do
            label="${fam:-default family}"
            if [ "$fam" = '-6' ] && ! ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
                skip 'IPv6 egress check (no global IPv6 in this container)'
                continue
            fi
            # shellcheck disable=SC2086 # $fam is intentionally unquoted/empty
            if curl $fam -sS --max-time 5 -o /dev/null https://example.com 2>/dev/null; then
                bad "example.com is reachable over ${label} -- egress is not restricted"
            else
                ok "example.com is blocked over ${label}"
            fi
        done
        ;;
    off)
        skip 'egress checks (firewall is off by configuration)'
        ;;
    *)
        bad "firewall.state is '${fw_state}'; postStartCommand did not run"
        ;;
esac

echo
echo '== hatch =='
# hatch is available alongside uv. What matters is that its state lands on the volume
# rather than in the workspace or an image layer, and that it reuses the image's uv
# instead of downloading a second private copy.
# No `"$` anchor: hatch renders the TOML through rich, which pads every line out to
# the terminal width, so each value carries trailing spaces.
hatch_data="$(hatch config show 2>/dev/null | sed -n 's/^data *= *"\([^"]*\)".*$/\1/p')"
case "$hatch_data" in
    "$HOME"/.local/share/hatch) ok "hatch data dir is on the volume (${hatch_data})" ;;
    '')                         bad 'could not read hatch data dir from `hatch config show`' ;;
    *)                          bad "hatch data dir is ${hatch_data}, expected ~/.local/share/hatch" ;;
esac
if [ "${HATCH_ENV_TYPE_VIRTUAL_UV_PATH:-}" = "$(command -v uv)" ]; then
    ok 'hatch is pointed at the image uv, not a private download'
else
    bad "HATCH_ENV_TYPE_VIRTUAL_UV_PATH is '${HATCH_ENV_TYPE_VIRTUAL_UV_PATH:-<unset>}', expected $(command -v uv)"
fi

echo
echo '== python project workflow =='
if [ -f pyproject.toml ]; then
    check 'uv sync' uv sync --all-groups
    check 'uv run python' uv run python -c 'import sys; sys.exit(0)'
    check 'ruff check' ruff check .
else
    skip 'project workflow (no pyproject.toml in the workspace)'
fi

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
