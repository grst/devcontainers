#!/usr/bin/env bash
# Smoke test, run inside a built container.
#
#   podman run --rm -v "$PWD/test/python:/workspace" <image> bash /workspace/smoke.sh
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
    local desc="$1" out why; shift
    if out="$("$@" 2>&1)"; then
        ok "$desc"
    else
        # The last line of output, when there is one. A check that fails without
        # saying why sends you off to run the command by hand, which is what this
        # file exists to save you -- and podman in particular reports one-line
        # errors that name exactly what it could not do.
        why="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
        bad "${desc}${why:+ -- ${why}}"
    fi
}

echo
echo '== tools on PATH =='
for tool in zsh git gh jq yq fzf fd rg rga bat delta mlr tree nvim tmux direnv \
            node npm claude copilot ipset iptables dig \
            podman crun fuse-overlayfs pasta newuidmap \
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
# devcontainer-isolation is authoritative for the mount scan, the runtime socket, the
# forwarded agent and the credential directories -- it is invoked below rather than
# reimplemented here, which is how the two copies of its pseudo-filesystem ignore list
# drifted apart in the first place.
check 'the isolation check itself passes' sudo /usr/local/bin/devcontainer-isolation

# Not covered by that check: the mount flag says nothing about ownership, and a
# workspace owned by a uid this container cannot map surfaces far downstream as a
# mystery `uv sync` failure instead of an isolation failure.
if touch /workspace/.write-probe 2>/dev/null; then
    rm -f /workspace/.write-probe
    ok '/workspace is writable'
else
    bad "/workspace is not writable by $(id -un) -- it is owned by uid $(stat -c %u /workspace)"
fi
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

# The two things CAP_SYS_ADMIN and unmask=/proc/* would cost if the reasoning in
# devcontainer.json were wrong. Both are probed as root, because as the container
# user they would fail for a boring lack of privilege and prove nothing.
#
# Only meaningful in a rootless container: an identity uid_map means a rootful
# runtime (docker in CI), where CAP_SYS_ADMIN really is host-level privilege and a
# remount really does succeed. Skipping there is the honest result, not a pass.
if grep -qE '^\s*0\s+0\s+4294967295' /proc/self/uid_map; then
    skip 'CAP_SYS_ADMIN containment (rootful runtime; not how this image is run)'
else
    ro_mount="$(awk '$0 ~ / - / {
                       opts = $6; tgt = $5;
                       fstype = $0; sub(/.* - /, "", fstype); sub(/ .*/, "", fstype)
                       if (opts ~ /(^|,)ro(,|$)/ && fstype !~ /^(proc|sysfs|tmpfs|devpts|mqueue|cgroup2?|bpf|nsfs|devtmpfs|securityfs|tracefs|debugfs|fusectl|pstore|configfs|binfmt_misc|efivarfs)$/ && tgt !~ /^\/(proc|sys|dev)(\/|$)/) { print tgt; exit }
                   }' /proc/self/mountinfo)"
    if [ -n "$ro_mount" ]; then
        if sudo mount -o remount,rw "$ro_mount" 2>/dev/null; then
            sudo mount -o remount,ro "$ro_mount" 2>/dev/null
            bad "a read-only mount (${ro_mount}) could be remounted rw -- the kernel is not locking inherited mounts, so ro host binds are not actually ro"
        else
            ok "a read-only mount (${ro_mount}) cannot be remounted rw even as root"
        fi
    else
        skip 'ro-remount probe (no read-only host mount in this container)'
    fi

    # A non-namespaced sysctl: writable only with privilege in the host's user
    # namespace, which this container does not have however root it looks inside.
    # drop_caches is the harmless one to pick -- if the write ever did land, the
    # host loses some page cache and nothing else.
    if echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1; then
        bad 'a non-namespaced host sysctl (vm.drop_caches) was writable -- this container has more than a rootless user namespace'
    else
        ok 'non-namespaced host sysctls stay unwritable (vm.drop_caches)'
    fi
fi

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
        # Only the positive half. devcontainer-firewall's own verification probes
        # example.com per family and refuses to write state=on unless every one of
        # them was blocked, so reaching this branch at all has already asserted it.
        #
        # HEAD, not GET. https://pypi.org/simple/ is the full index -- 44 MB -- so a
        # GET with any sane --max-time reports a timeout that looks exactly like the
        # host being blocked. This probe is about reachability, so ask for headers.
        if curl -fsS -I --max-time 10 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
            ok 'an allowlisted host (pypi.org) is reachable'
        else
            bad 'an allowlisted host (pypi.org) is NOT reachable'
        fi
        ;;
    off)
        # Not a skip. "firewall off" means unrestricted egress, so the interesting
        # assertion is that egress actually *works* -- and nothing here used to check
        # that, so a container with no working DNS at all passed every check while
        # `claude` could not reach the API and curl failed on every hostname.
        #
        # DNS is checked separately from TCP because the two failures look identical
        # from curl but have nothing to do with each other: a black-holed nameserver
        # (the pasta map-host-loopback address not matching what podman wrote into
        # resolv.conf) versus no route at all.
        if getent hosts api.anthropic.com >/dev/null 2>&1; then
            ok 'DNS resolves (api.anthropic.com)'
        else
            bad "DNS does not resolve. nameservers: $(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf)"
        fi
        for host in https://api.anthropic.com https://example.com; do
            if curl -sS -I --max-time 10 -o /dev/null "$host" 2>/dev/null; then
                ok "${host} is reachable (egress is unrestricted)"
            else
                bad "${host} is NOT reachable, but the firewall is off -- egress is broken"
            fi
        done
        ;;
    *)
        bad "firewall.state is '${fw_state}'; postStartCommand did not run"
        ;;
esac

echo
echo '== nested containers (podman) =='
# Rootless podman inside a rootless container has four prerequisites from the
# runtime, and podman names none of them when they are missing -- it reports a
# newuidmap EPERM, or a tap device it could not open. So each is checked on its
# own here, and the failure message says which runArg to put back. (podman and the
# helpers it needs are in the tools list above.)
check '/dev/net/tun is passed through (pasta needs a tap device)' test -c /dev/net/tun
check '/dev/fuse is passed through (fuse-overlayfs storage fallback)' test -c /dev/fuse

# CAP_SYS_ADMIN, read out of the bounding set rather than with capsh, which is a
# package this image does not otherwise need. Bit 21 is CAP_SYS_ADMIN.
if (( 0x$(awk '/^CapBnd:/ {print $2}' /proc/self/status) & (1 << 21) )); then
    ok 'CAP_SYS_ADMIN is present (newuidmap cannot map the nested range without it)'
else
    bad 'CAP_SYS_ADMIN is missing -- add "--cap-add=SYS_ADMIN" to runArgs, or podman fails with `newuidmap: write to uid_map failed`'
fi

# A nested container has to mount a fresh procfs, and the kernel refuses while any
# locked submount under /proc would be hidden by it -- which is exactly what
# podman's masked and read-only /proc paths are.
masked_proc="$(awk '$5 ~ /^\/proc\// {printf "%s ", $5}' /proc/self/mountinfo)"
if [ -z "$masked_proc" ]; then
    ok 'nothing is mounted under /proc (a nested container can mount procfs)'
else
    bad "masked submounts under /proc (${masked_proc}) -- add \"--security-opt=unmask=/proc/*\" to runArgs, or every \`podman run\` fails with \`mount 'proc' to 'proc': Operation not permitted\`"
fi

# The nested subuid range must consist of ids the *outer* user namespace actually
# maps, and must not contain the container user's own uid. The image ships ranges
# that fit --userns=keep-id; this catches a base-image default coming back, or a
# host with a smaller subuid range than the usual 65536.
outer_max="$(awk '{ last = $1 + $3 - 1; if (last > max) max = last } END { print max + 0 }' /proc/self/uid_map)"
self_uid="$(id -u)"
subuid_problem=''
while IFS=: read -r user start count; do
    [ "$user" = "$(id -un)" ] || continue
    [ -n "$count" ] || continue
    if (( start + count - 1 > outer_max )); then
        subuid_problem="${start}:${count} reaches id $(( start + count - 1 )), but the outer user namespace only maps up to ${outer_max}"
    elif (( self_uid >= start && self_uid < start + count )); then
        subuid_problem="${start}:${count} contains the container user's own uid ${self_uid}"
    fi
done < /etc/subuid
if [ -z "$subuid_problem" ]; then
    ok "/etc/subuid fits the outer user namespace (ids 0-${outer_max})"
else
    bad "/etc/subuid: ${subuid_problem} -- newuidmap will fail with EPERM"
fi

# And the thing all of the above exists for.
if podman info >/dev/null 2>&1; then
    ok 'podman info (user namespace, storage and runtime all resolve)'

    # Everything past here needs an image, which needs egress to a registry. A pull
    # that cannot reach one is a skip, not a failure: the checks below are about
    # nested containers working, and this file is meant to run offline too.
    nested_image='docker.io/library/alpine:3.22'
    if podman pull -q "$nested_image" >/dev/null 2>&1; then
        check 'podman run in a nested container' podman run --rm "$nested_image" true
        # Runs as a uid other than the container user's, which is the half of the
        # mapping that only works because /etc/subuid is right.
        check 'a nested container can run as another uid' \
            podman run --rm --user 405:100 "$nested_image" true
        # `podman build` takes a different path to the same namespaces (buildah,
        # mounting the build container's /proc), and it is the one an agent reaches
        # for most.
        build_dir="$(mktemp -d)"
        printf 'FROM %s\nRUN echo built > /probe\n' "$nested_image" > "${build_dir}/Dockerfile"
        check 'podman build' podman build -q -t smoke-nested:1 "$build_dir"
        rm -rf "$build_dir"
        podman rmi -f smoke-nested:1 >/dev/null 2>&1

        # The one that matters for the firewall's promise: pasta forwards the nested
        # container's traffic through sockets in *this* container's network
        # namespace, so the allowlist applies to it too. If it did not, a nested
        # container would be a one-command way around firewall=on.
        if [ "$fw_state" = on ]; then
            if podman run --rm "$nested_image" \
                wget -qO /dev/null -T 8 https://example.com >/dev/null 2>&1
            then
                bad 'a nested container reached a non-allowlisted host -- nested containers bypass the firewall'
            else
                ok 'a nested container is subject to the egress allowlist too'
            fi
            # pypi.org, not pypi.org/simple/ -- busybox wget has no HEAD, and the
            # full index is 44 MB, so a GET there times out and reads as blocked.
            if podman run --rm "$nested_image" \
                wget -qO /dev/null -T 8 https://pypi.org/ >/dev/null 2>&1
            then
                ok 'a nested container can reach an allowlisted host'
            else
                bad 'a nested container cannot reach pypi.org, which is allowlisted'
            fi
        else
            skip 'nested egress under the allowlist (firewall is off)'
        fi
    else
        skip "nested run/build (could not pull ${nested_image}; needs egress to a registry)"
    fi
else
    # A denied mount here, with CAP_SYS_ADMIN present, is almost always a mandatory
    # access control profile on the *outer* container rather than anything podman
    # did: docker's docker-default AppArmor profile denies every mount operation, so
    # storage setup fails with `failed to make mount private: ... permission denied`.
    # Report the profile next to podman's own error, because podman never mentions it.
    bad "podman info failed: $(podman info 2>&1 | tail -1) [outer AppArmor profile: $(cat /proc/self/attr/current 2>/dev/null || echo 'none')]"
fi

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
