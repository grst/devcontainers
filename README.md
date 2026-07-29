# devcontainers

Personal dev container base images, plus a template for dropping the setup into a
repository. Built for running Claude Code in auto mode with the host out of reach,
and for being equally usable from a terminal and from VS Code.

| | |
| --- | --- |
| `ghcr.io/grst/devcontainers/base` | zsh + dotfiles, CLI tools, Claude Code, the firewall and isolation checks. No language toolchain. |
| `ghcr.io/grst/devcontainers/python` | the above plus uv and hatch, Python 3.14, ruff, prek, headless Chrome. |
| `ghcr.io/grst/devcontainer-templates/python` | the devcontainer Template that generates a repo's `.devcontainer/`. |

A future `rust/Dockerfile` layers on the same base and inherits all of it. Nothing
rust ships today.

## Use it in a repository

```bash
cd ~/projects/grst/some-repo

devcontainer templates apply \
  -t ghcr.io/grst/devcontainer-templates/python:1 \
  -a '{"firewall":"on"}'

.devcontainer/up.sh      # build/start under rootless podman, drop into zsh
claude                   # starts in auto mode; shift+tab reaches bypass
```

`firewall` has no default and the apply fails without it — see
[the firewall](#the-firewall-is-a-mandatory-choice). The other options
(`pythonVersion`, `peonPing`, `imageTag`) all have sensible defaults.

Re-applying the template over an existing `.devcontainer/` is how you upgrade a repo.
`post-create.sh` is idempotent and safe to re-run by hand at any time, which is what
you want after adding a `pyproject.toml` to a repo that did not have one.

| Task | Command, from the repo root |
| --- | --- |
| One-off command in the container | `devcontainer exec --workspace-folder . --docker-path podman uv run pytest` |
| Rebuild after editing the config | `.devcontainer/up.sh --remove-existing-container` |
| Rebuild ignoring the layer cache | `.devcontainer/up.sh --remove-existing-container --build-no-cache` |
| Find the container | `podman ps -a --filter label=devcontainer.local_folder=$PWD` |
| Throw away caches, venvs and the Claude login | `podman volume ls -q --filter name=$(basename $PWD) \| xargs -r podman volume rm` |

A shell function worth having on the host, since `--docker-path` has to be repeated
on every invocation:

```bash
dcx() { devcontainer exec --workspace-folder . --docker-path podman "$@"; }
# dcx claude -p 'run the test suite and fix what fails'
```

## The isolation contract

Two goals. Everything in the setup follows from them, and anything that served
neither was left out.

**1. The agent cannot modify anything on the host.** `/workspace` is the only
writable window onto host files. Everything else is a podman *named volume* — which
lives in podman's own storage, not at a host path — or is mounted read-only.

**2. No host secret reaches the agent** beyond the ones deliberately handed to it.
Never mounted at any permission: `~/.ssh`, `~/.gnupg`, `~/.config/gh`, and the host
`~/.claude` **root**. (The peon-ping mount targets the `hooks/peon-ping`
subdirectory, which exposes none of those.)

**A forwarded SSH agent is the worst case, and the easiest to get by accident.** An
agent socket is a signing oracle for *every* host that trusts the key — nothing
scopes it to git, or to GitHub. An agent in the container could `ssh` to one of those
machines and run commands there, and those machines are outside the container
boundary entirely. That is a bigger blast radius than writing to the host, and the
egress firewall does not contain it: the target may be allowlisted, and with
`firewall=off` nothing is blocked at all. So it is a hard failure rather than a
setting to remember.

Nothing here needs SSH: reads go over HTTPS with the read-only `GH_TOKEN`, and writes
come from `gh auth login` run inside the container.

`devcontainer-isolation` runs first in `postStartCommand` and **fails
`devcontainer up`** if any of that is violated. It compares `/proc/self/mountinfo`
against `/etc/devcontainer/mount-allowlist.txt`, and separately rejects a mounted
container runtime socket, a set `SSH_AUTH_SOCK`, and a non-empty `~/.ssh` /
`~/.gnupg` / `~/.config/gh`.

The runtime socket check matters more than all the others together: with a socket the
agent can start a privileged container and write anywhere on the host, and no amount
of care about the other mounts would help.

A legitimate extra mount is declared rather than exempted:

```jsonc
"mounts": ["source=${localEnv:HOME}/models,target=/opt/models,type=bind,readonly"],
"containerEnv": { "DEVCONTAINER_EXTRA_MOUNTS": "/opt/models:ro" }
```

### Why the check is inside the container

VS Code's Dev Containers extension
[forwards your host SSH agent and copies your host `~/.gitconfig`](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials)
on its own. Those are *application-scoped user* settings, so a repository cannot turn
them off. Checking from inside means the guarantee holds however the container was
started.

The copied `~/.gitconfig` is not a security problem — it is not a secret, and a
credential helper named in it cannot work without the credential store, which is
never mounted. It is a *functional* problem: the host config sets
`commit.gpgSign = true` with a signing key under `~/.ssh`, and with no key in the
container every commit would fail. Two independent fixes are in place, so it works
either way:

- the user setting below, and
- `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0=commit.gpgsign` / `GIT_CONFIG_VALUE_0=false`
  in `containerEnv`, which overrides any config file without writing to one.

### What this does not protect against

The container user has passwordless `sudo`, which every devcontainer base image
provides and which normal development depends on. So an agent that *decides* to
disable the firewall or edit the allowlist can. The firewall stops a prompt-injected
or careless agent from reaching the internet; it is not a boundary against one that
sets out to escape. The container itself is the boundary that holds.

## The firewall is a mandatory choice

There is no default anywhere, and the gate is implemented at two independent layers
so that hand-editing the generated config cannot silently disable it.

**Layer 1, the template.** `options.firewall` declares `enum: ["on", "off"]` with no
`default`, so `devcontainer templates apply` cannot proceed without a value. The
`templates` workflow asserts that no default ever gets added.

**Layer 2, the runtime.** `devcontainer-firewall` runs as `postStartCommand`, and:

| `DEVCONTAINER_FIREWALL` | |
| --- | --- |
| unset, or anything other than `on`/`off` | prints what to set and why, exits non-zero → **`devcontainer up` fails** |
| `on` | asserts `NET_ADMIN` really is present, builds the ipset, default-DROPs egress, then **verifies** by probing one allowed and one blocked host |
| `off` | warns that egress is unrestricted, succeeds |

That last verification step is there because installing rules is not the same as rules
taking effect. It has already caught a real hole, worth spelling out because
[Anthropic's reference `init-firewall.sh`](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh)
has the same one: **it is IPv4-only.** With rootless podman and pasta the container
inherits the host's global IPv6 addresses, so an IPv4 ruleset looks entirely correct
under `iptables -S` — policy DROP, allowlist matched, `ipset test` says a blocked
address is not in the set — while `ip6tables` sits at `policy ACCEPT` with no rules.
Since curl prefers IPv6, *every* real request took the unfiltered path. Forcing
`curl -4` was correctly blocked; nothing else was.

So the firewall here configures both families, with separate `inet` and `inet6`
ipsets built from A and AAAA records, and ICMPv6 plus link-local and multicast
explicitly allowed — dropping ICMPv6 breaks IPv6 outright rather than restricting it,
since neighbour discovery rides on it. The verification then probes `-4` and `-6`
separately *and* once with the default family selection, so this cannot regress
quietly again. If any probe disagrees with the intent, the container fails rather than
reporting a firewall it does not have.

The active state is written to `/run/devcontainer/firewall.state`, which the shell
prompt and the Claude Code status line both display, so an unattended session never
leaves you guessing.

### Extending the allowlist

Drop a `.txt` file into `/etc/devcontainer/firewall-allowlist.d/`, numbered above
`00`, rather than editing the base list — that way your additions survive a base
image rebuild:

```dockerfile
RUN echo 'my-registry.example.com' \
    > /etc/devcontainer/firewall-allowlist.d/50-project.txt
```

One entry per line: a domain (every A record it resolves to is allowed), a CIDR
block, a bare address, or `+github-meta` to expand GitHub's published ranges. The
last one matters because `github.com`, `api.github.com` and friends sit behind large
rotating pools, so a resolved A record goes stale within minutes.

## Claude Code

Sessions start in **auto mode**: a classifier reviews each action before it runs,
rather than nothing reviewing it. `post-create.sh` writes
`permissions.defaultMode = "auto"` into `$CLAUDE_CONFIG_DIR/settings.json` on the
config volume. It has to go there and not into a repo's `.claude/settings.json` —
Claude Code deliberately ignores `auto` from project settings so a repository cannot
grant itself auto mode. The volume is user scope *inside the container*, so it works
there and affects nothing on the host.

`bypassPermissions` is available but not active: the container's `claude()` shell
function passes `--allow-dangerously-skip-permissions`, which adds bypass to the
shift+tab cycle without turning it on. Reach for it when auto mode's fallback gets in
the way — after 3 consecutive or 20 total classifier blocks auto mode pauses and
starts prompting, and in headless `claude -p` runs repeated blocks abort the session.
Bypass never stops.

The status line (context usage, session tokens, elapsed time, rate limits, cost)
lives at `/usr/local/share/devcontainer/statusline.sh` in the image, so there is one
copy to maintain rather than one vendored per repo.

## Secrets: KeePassXC on the host, environment variables into the container

Nothing sensitive is mounted, so credentials arrive as environment variables that
`up.sh` resolves on the host via `host-secrets.sh`. Each one is looked up as: already
exported → Secret Service (KeePassXC FdoSecrets) → `keepassxc-cli`, which prompts once
for the master password and reuses it for every entry.

**A secret that cannot be resolved is fatal**: `up.sh` prints which lookup layer was
unavailable and refuses to create the container. To start one anyway, say so:

```bash
DEVCONTAINER_SKIP_SECRETS=1 .devcontainer/up.sh
```

This used to be a warning, which turned out to be useless — a stopped KeePassXC, a
mistyped entry title and a `host-secrets.sh` that had lost its exec bit all produced
the same silent success, and the first sign of trouble was `claude` not being logged in
inside a container that had already started.

| Variable | KeePassXC entry title | Notes |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | `Anthropic API key` | Without it, `claude` uses the login stored in the config volume, which survives rebuilds. |
| `GH_TOKEN` | `GitHub read-only token (devcontainer)` | Must be **read-only**. |

The `keepassxc-cli` layer needs no configuration: the database is discovered from
`LastActiveDatabase` in `~/.cache/keepassxc/keepassxc.ini` — the *cache* config, which
is where KeePassXC 2.7+ records the databases it would reopen. Set `KEEPASSXC_DB` to
override. Entries inside a group are found by title via `keepassxc-cli locate`, so
`show`'s requirement for a full `Group/Title` path is not something you have to know.

Override a title per machine: `export ANTHROPIC_KEY_ENTRY=...`, `export
GH_TOKEN_ENTRY=...`.

**`GH_TOKEN` being read-only is the design, not a limitation.** It covers what an
agent needs constantly — clone, `gh api`, reading issues, PRs and CI logs — with no
host credential mounted, and because it cannot write, an agent in auto mode holding
it cannot push, open PRs, or change anything on GitHub. If it leaks, the damage is
"someone can read what you can read", which is a very different problem from a leaked
write token.

When you actually want to push, run **`gh auth login` inside the container**. That
credential lands in the container's own volume, not on the host, and disappears with
the volumes — so write access is an explicit act per container instead of an ambient
capability every session inherits.

Two things that will bite you otherwise:

- `up.sh` fetches secrets **before** repointing `DBUS_SESSION_BUS_ADDRESS` for
  podman. KeePassXC owns `org.freedesktop.secrets` on whichever session bus it was
  started on — usually the `dbus-launch` bus, not the systemd user bus — and asking
  the systemd user bus instead makes D-Bus try to activate a *second* KeePassXC and
  time out. Keep that order if you edit the script.
- `remoteEnv` means only `devcontainer exec` / `up.sh` / VS Code terminals see the
  secrets; a bare `podman exec` does not. And `${localEnv:...}` resolves against the
  *VS Code process* environment, so a desktop-launcher instance has nothing — start
  `code` from a shell that ran the fetch, or use the terminal workflow.
- **The VS Code path cannot fetch anything itself.** `up.sh` never runs there, and
  `initializeCommand` cannot export variables back to the CLI, so there is no hook that
  could reach KeePassXC. Reopen-in-Container therefore depends entirely on the
  variables already being in VS Code's environment. When they are not, `post-create.sh`
  says so in a banner rather than leaving you to discover it from `claude`.
- An unset host variable is not passed through as *unset*: the CLI substitutes
  `${localEnv:X}` with an empty string, so it arrives set-and-empty. The container
  `zshrc` unsets the empties, so a tool testing "is this set" does not try to
  authenticate with nothing and report it as a rejected credential.

KeePassXC one-time setup: *Settings → Secret Service Integration → Enable*, then
*Manage exposed database groups* and tick only the group holding these entries.
Exposing one group rather than the whole database keeps the blast radius small, since
every app on your session bus can read what is exposed. Verify without revealing
anything: `secret-tool lookup Title "Anthropic API key" | wc -c`.

## Shell

A curated subset of the host config, baked into the image. Source files live undotted
in `base/dotfiles/` and get their dots in the Dockerfile.

- **vi mode** with `KEYTIMEOUT=1` and a `-- NORMAL --` indicator on the right.
- **fzf**: `^R` history, `^T` files, `M-c` cd, all fd-backed. `^R` really is fzf's
  widget — `fzf.zsh` is sourced last precisely so it wins over zsh's builtin history
  search, and the smoke test asserts it.
- **History** on the `/commandhistory` volume, shared between shells, 10M entries,
  surviving rebuilds.
- Case-insensitive menu completion, `extendedglob`, `zmv`, `zargs`, `^x^e` to edit
  the current line in `$EDITOR`.
- A prompt that leads with the image flavour and firewall state, then the git branch
  and dirty marker.
- Aliases: `ll`/`la`/`l`, `st`/`co`/`ga`/`pu`/`pull`/`rcm`, `json`, mlr-backed
  `csv`/`tsv`, `vim`→`nvim`. Functions: `c`, `reload`, `rga-fzf`, `escape`.

**Deliberately dropped**, and the first one is the important one:

- `cp -i`, `mv -i`, `rm -v`, `ln -v`. The `-i` flags block on stdin, which stalls
  scripts and hangs an agent on what looks like a finished tool call. `cp`, `mv`, `rm`
  and `ln` are plain and unaliased.
- `commit.gpgSign` / `gpg.format=ssh` / `user.signingKey` — no key is mounted, so
  signing would fail every commit. Container commits are unsigned.
- Arch/`sudo` package aliases, `docker='sudo docker'`, X11 clipboard tools,
  `open=mimeopen`, `merge.tool=meld`.
- conda/micromamba, `~/anaconda3`, `MAMBA_ROOT_PREFIX` — uv is the toolchain here.
- ssh-agent bootstrap, `credential.helper`, `run_under_tmux`, `confirm`/`poweroff`
  wrappers, the `config` bare-repo alias.

## Python

**uv is the default; hatch is available.** `uv` drives the container's own
post-create (`uv sync --all-groups`) and handles a project that expresses no
preference, while a repo whose `pyproject.toml` defines hatch environments or a
version matrix works with no extra setup.

`UV_PYTHON=3.14` makes a bare `uv venv` / `uv sync` resolve to 3.14, while a
project's own `requires-python` or `.python-version` still wins. 3.14 and 3.13 are
baked in; anything else is downloaded on first use. `uv python install 3.12` works at
runtime, but lands in an image layer rather than a volume, so add the version to
`python/Dockerfile` if you want it to stick.

Three volumes keep Python state across rebuilds: `~/.cache` (which holds
`UV_CACHE_DIR` and hatch's cache), `~/.local/share/uv`, and `~/.local/share/hatch`.
So wheels, uv-managed interpreters, hatch environments and `hatch python install`
downloads all survive. Hatch's data directory is deliberately *not* in the workspace,
so it neither lands in the repo nor collides with a hatch run on the host.

`HATCH_ENV_TYPE_VIRTUAL_UV_PATH` points hatch at the uv already in the image. Left
unset, hatch downloads its own private copy the first time an environment uses
`installer = "uv"` — a second uv on a different release cadence, for no reason. To
have hatch resolve with uv, add to `pyproject.toml`:

```toml
[tool.hatch.envs.default]
installer = "uv"
```

`hatch python install 3.11 3.13` lands on the volume, so a matrix like
`[[tool.hatch.envs.test.matrix]] python = ["3.11", "3.12", "3.13"]` only downloads
once.

Globally available via `uv tool`, each isolated from any project venv and from each
other: `ruff`, `prek`, `pre-commit`, `hatch`, `ipython`, `zizmor`, `cruft`.

A headless browser is installed so an agent can look at rendered HTML. It is
**Google Chrome**, with `chromium` as a symlink to it, and that is not arbitrary: on
Ubuntu, `apt install chromium` gets you a *snap transitional package* — a 2.4 kB shell
script that shells out to snapd, which does not exist in a container. apt reports
success and leaves you with no working browser. (The Debian-based predecessor of this
image had a real chromium deb, which makes this an easy trap when porting.) Google
publishes no Chrome deb for arm64, so the python image fails the build loudly on that
arch rather than producing an image with no browser.

```bash
chromium --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --virtual-time-budget=3000 --window-size=1280,900 \
  --screenshot=/tmp/render.png file:///workspace/report.html
chromium --headless --no-sandbox --dump-dom file:///workspace/report.html
```

`--no-sandbox` is required: the browser's own sandbox needs privileges the container
does not have, and the container is already the isolation boundary. Chrome's deb also
pulls in the shared libraries Playwright's own build needs, so `playwright install
chromium` works without `--with-deps`.

## peon-ping

Claude Code hooks run *inside* the container, but sound and desktop notifications
happen on the host through peon-ping's relay:

```
container: peon.sh --HTTP--> host: peon relay --> PipeWire + notify-send
```

Enable with `-a '{"peonPing":"on"}'`. Three details make it work:

- `~/.claude/hooks/peon-ping` is bind-mounted **read-only** at `/opt/peon-ping`. Not
  a copy: a *writable* bind here would let an agent in bypass mode edit hook scripts
  that the **host** then executes, and read-only prevents that at the kernel instead
  of by mirroring. `initializeCommand` creates the directory on the host if it does
  not exist, because podman refuses to start on a missing bind source.
- `PEON_PLATFORM=devcontainer` is explicit: peon-ping's autodetection looks for
  `/.dockerenv` or `REMOTE_CONTAINERS`, podman writes `/run/.containerenv` instead, so
  it would otherwise think it is on a plain Linux host and try to play audio in the
  container.
- `--network=pasta:--map-host-loopback,169.254.1.2` lets the container reach the relay
  on the host's loopback, so the relay does not have to listen on `0.0.0.0` where the
  LAN could reach it. With `firewall=on`, `post-create.sh` adds that address to the
  allowlist; without `peonPing=on` it is not allowlisted and the host stays
  unreachable.

Check the path end to end:

```bash
curl -sS http://host.docker.internal:19998/health          # -> OK
printf '{"hook_event_name":"Stop","cwd":"/workspace"}' \
  | PEON_TEST=1 bash /opt/peon-ping/peon.sh
```

Accepted trade-off: this opens a network path from the container to one host service
that plays sounds and fires `notify-send`, so a compromised agent could spam those. It
cannot write host files through it. Use `peonPing=off` if you would rather not.

## Host prerequisites

Rootless **podman** and the [`devcontainer` CLI](https://github.com/devcontainers/cli)
(Arch: `devcontainer-cli` from the AUR, or `npm install -g @devcontainers/cli`;
`up.sh` falls back to `npx -y @devcontainers/cli`).

Podman needs the `overlay` kernel module, otherwise *every* build fails with
`mounting an overlay over build context directory: ... no such device`:

```bash
grep overlay /proc/filesystems || sudo modprobe overlay
echo overlay | sudo tee /etc/modules-load.d/overlay.conf   # persist
```

A `modprobe: FATAL: Module overlay not found in directory /lib/modules/<version>`
here means the running kernel no longer matches the modules on disk after a kernel
upgrade — reboot. Where you cannot load modules, set
`mount_program = "/usr/bin/fuse-overlayfs"` under `[storage.options.overlay]` in
`~/.config/containers/storage.conf` instead, though it may need `podman system reset`.

### If builds fail with `sd-bus call: ... Input/output error`

crun creates the container's cgroup scope by asking the session bus for
`org.freedesktop.systemd1`. On sessions started with `dbus-launch` (common with
`startx`), `DBUS_SESSION_BUS_ADDRESS` points at a plain dbus-daemon socket in `/tmp`
with no systemd service, and the call fails. `up.sh` works around it, but the VS Code
extension and bare `podman` calls inherit the broken value, so fix it at the session
level:

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"   # in ~/.zshrc
```

Podman-only fallback that bypasses sd-bus entirely (rootless containers then run
without cgroup resource limits), in `~/.config/containers/containers.conf`:

```toml
[engine]
cgroup_manager = "cgroupfs"
```

### VS Code

Three *user* settings — all application-scoped, so none of them can live in the repo:

```jsonc
{
  // podman instead of docker
  "dev.containers.dockerPath": "podman",
  // do not copy the host ~/.gitconfig in; it would bring commit.gpgSign=true with
  // it, and no signing key is mounted. Harmless if you forget -- the GIT_CONFIG_*
  // override in devcontainer.json covers it -- but cleaner this way.
  "dev.containers.copyGitConfig": false
}
```

Then *Dev Containers: Reopen in Container*. If the extension forwards a running SSH
agent, `devcontainer-isolation` will fail the container on purpose; stop the agent
before launching, or use `up.sh`.

## Repository layout

```
base/         the base image: Dockerfile, dotfiles/ (undotted), bin/, etc/
python/       the python image, FROM base
src/python/   the devcontainer Template (spec layout)
test/python/  fixture consumer repo + smoke.sh
```

Dotfiles are stored **undotted** (`base/dotfiles/zshrc`, not `.zshrc`) and get their
dots in the Dockerfile. That is partly convention for a dotfiles source directory and
partly necessity: this repo is edited by Claude Code with a sandbox whose `denyRead`
rules match dotfile *names* anywhere, which makes a checked-in `.zshrc` or
`.gitconfig` unreadable and unwritable from a sandboxed session. Same reason there is
no `.mcp.json` in the template — MCP setup is documented rather than generated.

Registry namespaces are split on purpose. `devcontainers/action` would publish a
template with id `python` to `ghcr.io/grst/devcontainers/python`, which is where the
*image* lives, so the templates workflow uses the CLI's `--namespace` to put them
under `ghcr.io/grst/devcontainer-templates/` instead.

Every downloaded version is an `ARG`: `grep -rn '^ARG .*VERSION' base python` lists
everything that needs bumping.

## Tests

`test/python/smoke.sh` runs inside a built container and checks the things that rot
silently — a tool gone from the archive, a dotfile that stopped parsing, `^R` no
longer bound to fzf, a gate that stopped gating.

```bash
podman run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e DEVCONTAINER_FIREWALL=off -v "$PWD/test/python:/workspace" \
  ghcr.io/grst/devcontainers/python:latest \
  bash -c 'sudo -E /usr/local/bin/devcontainer-firewall && bash smoke.sh'
```

CI additionally asserts the negative cases, which are the ones that matter: an unset
firewall choice fails the container, `firewall=on` without `NET_ADMIN` fails it, and
the isolation check fails on a writable extra mount, an `ro`-declared-but-`rw`-mounted
path, a forwarded SSH agent, and a mounted docker socket.
