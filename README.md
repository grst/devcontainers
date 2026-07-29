# devcontainers

A personal dev container image, plus a template for dropping the setup into a
repository. Built for running Claude Code in auto mode with the host out of reach, and
for being equally usable from a terminal and from VS Code.

| | |
| --- | --- |
| `ghcr.io/grst/devcontainers/python` | zsh + dotfiles, CLI tools, Claude Code, the firewall and isolation checks, uv + hatch, Python 3.14, ruff, prek, headless Chrome. |
| `ghcr.io/grst/devcontainer-templates/python` | the devcontainer Template that generates a repo's `.devcontainer/`. |

Every "why" in this repo lives once, at the code it explains. This file covers usage
and the two contracts; for the reasoning behind a particular line, read the file it is
in — `python/Dockerfile`, `python/bin/devcontainer-firewall`,
`python/bin/devcontainer-isolation`, `src/python/.devcontainer/*`.

## Use it in a repository

```bash
cd ~/projects/grst/some-repo

devcontainer templates apply \
  -t ghcr.io/grst/devcontainer-templates/python:0.0 \
  -a '{"firewall":"on"}'

.devcontainer/up.sh      # build/start under rootless podman, drop into zsh
claude                   # starts in auto mode; shift+tab reaches bypass
```

Template tags are explicit; `latest` is not reliable for these artifacts — `0.0` tracks
the newest build of `main`, and a release is an exact `X.Y.Z`. See
[publishing](#publishing).

`firewall` has no default, and the container refuses to start until it is set — see
[the firewall](#the-firewall-is-a-mandatory-choice). A non-interactive apply does not
itself refuse; it leaves the value empty and the runtime gate catches it. The other
options (`pythonVersion`, `peonPing`, `imageTag`) all have sensible defaults.

Re-applying the template over an existing `.devcontainer/` is how you upgrade a repo.
`post-create.sh` is idempotent and safe to re-run by hand, which is what you want after
adding a `pyproject.toml` to a repo that did not have one.

| Task | Command, from the repo root |
| --- | --- |
| One-off command in the container | `devcontainer exec --workspace-folder . --docker-path podman uv run pytest` |
| Rebuild after editing the config | `.devcontainer/up.sh --remove-existing-container` |
| Rebuild ignoring the layer cache | `.devcontainer/up.sh --remove-existing-container --build-no-cache` |
| Find the container | `podman ps -a --filter label=devcontainer.local_folder=$PWD` |
| Throw away caches, venvs and the Claude login | `podman volume ls -q --filter name=$(basename $PWD) \| xargs -r podman volume rm` |

A shell function worth having on the host, since `--docker-path` has to be repeated on
every invocation:

```bash
dcx() { devcontainer exec --workspace-folder . --docker-path podman "$@"; }
# dcx claude -p 'run the test suite and fix what fails'
```

## The isolation contract

Two goals. Everything in the setup follows from them, and anything that served neither
was left out.

**1. The agent cannot modify anything on the host.** `/workspace` is the only writable
window onto host files. Everything else is a podman *named volume* — which lives in
podman's own storage, not at a host path — or is mounted read-only.

**2. No host secret reaches the agent** beyond the ones deliberately handed to it.
Never mounted at any permission: `~/.ssh`, `~/.gnupg`, `~/.config/gh`, and the host
`~/.claude` **root**. (The peon-ping mount targets the `hooks/peon-ping`
subdirectory, which exposes none of those.)

`devcontainer-isolation` runs first in `postStartCommand` and **fails `devcontainer
up`** if any of that is violated: it compares `/proc/self/mountinfo` against
`/etc/devcontainer/mount-allowlist.txt`, and separately rejects a mounted container
runtime socket, a set `SSH_AUTH_SOCK`, and a non-empty `~/.ssh` / `~/.gnupg` /
`~/.config/gh`. The runtime socket and the forwarded agent are the two that matter most
— the script's header explains why each is worse than it looks.

It runs *inside* the container because VS Code's Dev Containers extension
[forwards your host SSH agent and copies your host `~/.gitconfig`](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials)
on its own, and those are application-scoped *user* settings that a repository cannot
turn off. Checking from inside means the guarantee holds however the container was
started. (The copied gitconfig is not a security problem, only a functional one: it
carries `commit.gpgSign = true` while no signing key is mounted. The `GIT_CONFIG_*`
override in `devcontainer.json` neutralises it.)

A legitimate extra mount is declared rather than exempted:

```jsonc
"mounts": ["source=${localEnv:HOME}/models,target=/opt/models,type=bind,readonly"],
"containerEnv": { "DEVCONTAINER_EXTRA_MOUNTS": "/opt/models:ro" }
```

**What this does not protect against.** The container user has passwordless `sudo`,
which every devcontainer image provides and which normal development depends on. So an
agent that *decides* to disable the firewall or edit the allowlist can. The firewall
stops a prompt-injected or careless agent from reaching the internet; it is not a
boundary against one that sets out to escape. The container itself is that boundary.

## The firewall is a mandatory choice

There is no default anywhere, and the gate is implemented at two independent layers so
that hand-editing the generated config cannot silently disable it.

**Layer 1, the template.** `options.firewall` declares `enum: ["on", "off"]` with no
`default`, so there is no value to fall back to and the VS Code template picker has to
ask. CI asserts that no default ever gets added.

Do not rely on layer 1 alone: a non-interactive `devcontainer templates apply` with the
option omitted **does not refuse**. It substitutes an empty string and exits 0, leaving
`"DEVCONTAINER_FIREWALL": ""` in the generated config — measured, and pinned by a test
so a change in CLI behaviour shows up. That is exactly why layer 2 exists.

**Layer 2, the runtime.** `devcontainer-firewall` runs as `postStartCommand`, and:

| `DEVCONTAINER_FIREWALL` | |
| --- | --- |
| unset, or anything other than `on`/`off` | prints what to set and why, exits non-zero → **`devcontainer up` fails** |
| `on` | asserts `NET_ADMIN` really is present, builds the ipset, default-DROPs egress over **both** families, then **verifies** by probing an allowed and a blocked host per family |
| `off` | warns that egress is unrestricted, succeeds |

The verification exists because installing rules is not the same as rules taking
effect; it has already caught a real IPv4-only hole that `iptables -S` showed as
perfectly correct. The script's header has the postmortem. If any probe disagrees with
the intent, the container fails rather than reporting a firewall it does not have.

The active state is written to `/run/devcontainer/firewall.state`, which the shell
prompt and the Claude Code status line both display, so an unattended session never
leaves you guessing.

### Extending the allowlist

Drop a `.txt` file into `/etc/devcontainer/firewall-allowlist.d/`, numbered above `00`,
rather than editing the shipped list — that way your additions survive an image
rebuild:

```dockerfile
RUN echo 'my-registry.example.com' \
    > /etc/devcontainer/firewall-allowlist.d/50-project.txt
```

One entry per line: a domain (every A and AAAA record it resolves to is allowed), a
CIDR block, a bare address, or `+github-meta` to expand GitHub's published ranges. The
last one matters because `github.com` and friends sit behind large rotating pools, so a
resolved A record goes stale within minutes.

## Claude Code

Sessions start in **auto mode**: a classifier reviews each action before it runs, rather
than nothing reviewing it. `post-create.sh` writes `permissions.defaultMode = "auto"`
into `$CLAUDE_CONFIG_DIR/settings.json` on the config volume — it has to go to user
scope, because Claude Code deliberately ignores `auto` from a repo's settings so a
repository cannot grant itself auto mode.

`bypassPermissions` is available but not active: the container's `claude()` shell
function passes `--allow-dangerously-skip-permissions`, which adds bypass to the
shift+tab cycle without turning it on. Reach for it when auto mode's fallback gets in
the way — after 3 consecutive or 20 total classifier blocks auto mode pauses and starts
prompting, and in headless `claude -p` runs repeated blocks abort the session.

The status line (context usage, session tokens, elapsed time, rate limits, cost) lives
at `/usr/local/share/devcontainer/statusline.sh` in the image, so there is one copy to
maintain rather than one vendored per repo.

## Secrets: KeePassXC on the host, environment variables into the container

Nothing sensitive is mounted, so credentials arrive as environment variables that
`up.sh` resolves on the host via `host-secrets.sh`: already exported → Secret Service
(KeePassXC's FdoSecrets integration, which needs no master password while the database
is unlocked).

**A secret that cannot be resolved is fatal**: `up.sh` prints what was unavailable and
refuses to create the container. To start one anyway, say so:

```bash
DEVCONTAINER_SKIP_SECRETS=1 .devcontainer/up.sh
```

| Variable | KeePassXC entry title | Notes |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | `Anthropic API key` | Without it, `claude` uses the login stored in the config volume, which survives rebuilds. |
| `GH_TOKEN` | `GitHub read-only token (devcontainer)` | Must be **read-only**. |

Override a title per machine: `export ANTHROPIC_KEY_ENTRY=…`, `export
GH_TOKEN_ENTRY=…`.

**`GH_TOKEN` being read-only is the design, not a limitation.** It covers what an agent
needs constantly — clone, `gh api`, reading issues, PRs and CI logs — with no host
credential mounted, and an agent in auto mode holding it cannot push or change anything
on GitHub. When you actually want to push, run **`gh auth login` inside the
container**: that credential lands in the container's own volume and disappears with
it, so write access is an explicit act per container rather than an ambient capability.

Two things that will bite you otherwise:

- `up.sh` fetches secrets **before** repointing `DBUS_SESSION_BUS_ADDRESS` for podman,
  and that order is load-bearing — the script says why.
- **The VS Code path cannot fetch anything itself.** `up.sh` never runs there and
  `initializeCommand` cannot export variables back to the CLI, so Reopen-in-Container
  depends entirely on the variables already being in VS Code's environment. Start
  `code` from a shell that has them, or run `claude` once in the container and log in.

KeePassXC one-time setup: *Settings → Secret Service Integration → Enable*, then
*Manage exposed database groups* and tick only the group holding these entries.
Exposing one group rather than the whole database keeps the blast radius small, since
every app on your session bus can read what is exposed. Verify without revealing
anything: `secret-tool lookup Title "Anthropic API key" | wc -c`.

## Shell

A curated subset of the host config, baked into the image. Source files live undotted
in `python/dotfiles/` and get their dots in the Dockerfile.

- **vi mode** with `KEYTIMEOUT=1` and a `-- NORMAL --` indicator on the right.
- **fzf**: `^R` history, `^T` files, `M-c` cd, all fd-backed.
- **History** on the `/commandhistory` volume, shared between shells, surviving
  rebuilds.
- Case-insensitive menu completion, `extendedglob`, `zmv`, `zargs`, `^x^e` to edit the
  current line in `$EDITOR`.
- A prompt that leads with the image flavour and firewall state, then the git branch
  and dirty marker.
- Aliases: `ll`/`la`/`l`, `st`/`co`/`ga`/`pu`/`pull`/`rcm`, `json`, mlr-backed
  `csv`/`tsv`, `vim`→`nvim`. Functions: `c`, `reload`, `rga-fzf`, `escape`.

`cp`, `mv`, `rm` and `ln` are deliberately **unaliased**: the usual `-i` flags block on
stdin, which stalls scripts and hangs an agent on what looks like a finished tool call.
The smoke test asserts it.

## Python

**uv is the default; hatch is available** for repos whose `pyproject.toml` expects it,
with its state on a named volume so environments and managed interpreters survive a
rebuild.

`UV_PYTHON=3.14` makes a bare `uv venv` / `uv sync` resolve to 3.14, while a project's
own `requires-python` or `.python-version` still wins. 3.14 and 3.13 are baked in;
anything else is downloaded on first use. `uv python install 3.12` works at runtime but
lands in an image layer rather than a volume, so add the version to `python/Dockerfile`
if you want it to stick.

Globally available via `uv tool`, each isolated from any project venv and from each
other: `ruff`, `prek`, `pre-commit`, `hatch`, `ipython`, `zizmor`, `cruft`.

A headless browser is installed so an agent can look at rendered HTML — Google Chrome,
with `chromium` as a symlink to it (the Dockerfile explains why not `apt install
chromium`):

```bash
chromium --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --virtual-time-budget=3000 --window-size=1280,900 \
  --screenshot=/tmp/render.png file:///workspace/report.html
chromium --headless --no-sandbox --dump-dom file:///workspace/report.html
```

`--no-sandbox` is required: the browser's own sandbox needs privileges the container
does not have, and the container is already the isolation boundary.

## peon-ping

Claude Code hooks run *inside* the container, but sound and desktop notifications
happen on the host, so `peon.sh` posts over HTTP to a relay on the host loopback that
drives PipeWire and `notify-send`. Enable with `-a '{"peonPing":"on"}'`.

`~/.claude/hooks/peon-ping` is bind-mounted **read-only** at `/opt/peon-ping` — a
writable bind here would let an agent in bypass mode edit hook scripts that the *host*
then executes. The container reaches the relay through pasta's mapped host loopback,
which `post-create.sh` allowlists only when `peonPing=on`, so `firewall=on` otherwise
keeps the host unreachable.

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
(Arch: `devcontainer-cli` from the AUR, or `npm install -g @devcontainers/cli`; `up.sh`
falls back to `npx -y @devcontainers/cli`).

Podman needs the `overlay` kernel module, otherwise *every* build fails with
`mounting an overlay over build context directory: … no such device`:

```bash
grep overlay /proc/filesystems || sudo modprobe overlay
echo overlay | sudo tee /etc/modules-load.d/overlay.conf   # persist
```

A `modprobe: FATAL: Module overlay not found in directory /lib/modules/<version>` here
means the running kernel no longer matches the modules on disk after a kernel upgrade —
reboot. Where you cannot load modules, set
`mount_program = "/usr/bin/fuse-overlayfs"` under `[storage.options.overlay]` in
`~/.config/containers/storage.conf` instead, though it may need `podman system reset`.

### If builds fail with `sd-bus call: … Input/output error`

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

Two *user* settings — both application-scoped, so neither can live in the repo:

```jsonc
{
  "dev.containers.dockerPath": "podman",
  // Do not copy the host ~/.gitconfig in. Harmless if you forget, since the
  // GIT_CONFIG_* override in devcontainer.json covers it, but cleaner this way.
  "dev.containers.copyGitConfig": false
}
```

Then *Dev Containers: Reopen in Container*. If the extension forwards a running SSH
agent, `devcontainer-isolation` will fail the container on purpose; stop the agent
before launching, or use `up.sh`.

## Repository layout

```
python/       the image: Dockerfile, dotfiles/ (undotted), bin/, etc/
src/python/   the devcontainer Template (spec layout)
test/         cases.sh (gate + isolation cases), python/ (fixture repo + smoke.sh)
```

Registry namespaces are split on purpose. `devcontainers/action` would publish a
template with id `python` to `ghcr.io/grst/devcontainers/python`, which is where the
*image* lives, so the publish workflow uses the CLI's `--namespace` to put templates
under `ghcr.io/grst/devcontainer-templates/` instead.

Every downloaded version is an `ARG`: `grep -n '^ARG .*VERSION' python/Dockerfile`
lists everything that needs bumping. The image is amd64-only.

## Publishing

One workflow, `publish.yaml`, builds the image and the template in the same run from the
same commit — because the template's `devcontainer.json` is what names the image, and
publishing them on separate triggers is what let them drift.

| Trigger | Image | Template |
| --- | --- | --- |
| push to `main` | `latest`, `sha-<short>` | `0.0.0-main.g<short>`, `0.0`, `0` |
| tag `v0.1.0` | `0.1.0`, `0.1`, `0`, `latest` | `0.1.0`, `0.1`, `0`, and `latest` if it is the greatest version published |

**Pin an explicit template tag; do not rely on `latest`.** The `devcontainer` CLI
decides that tag itself, and only moves it onto the greatest version already published —
so a main build, which is a prerelease below every release, usually will not get it. The
first main publish produced `0`, `0.0`, `0.0.0-main.g<sha>` and no `latest` at all,
which is worth knowing before wondering why `apply -t …:latest` fails. Each publish
prints exactly what it pushed:

```
{"python":{"publishedTags":["0","0.0","0.0.0-main.g60947ed"],"version":"0.0.0-main.g60947ed"}}
```

A bare major is not a release line either — since main publishes `0.0.0-main.…`, the
`0` tag moves with main as well as with `0.x` releases. That is the CLI's tag scheme,
not a choice this repo makes. `0.0` is a usable short handle for the newest main build,
since main builds are the only thing publishing `0.0.x` versions until an actual
`v0.0.x` release exists.

The template's version comes from the ref, never from the repo;
`.github/scripts/stamp-templates.sh` derives it and explains the details. A release also
stamps `options.imageTag.default` to the version being released, so applying
`…/python:0.1.0` pins you to the image built in that same run. The copy published from
`main` keeps `latest`.

Template *sources* are validated in `test.yaml` on every pull request — id matches the
directory, every `${templateOption:…}` is declared, `options.firewall` still has no
default, and the `.devcontainer/*.sh` scripts are mode `100755`.

## Tests

`test/python/smoke.sh` runs inside a built container and checks the things that rot
silently — a tool gone from the archive, a dotfile that stopped parsing, `^R` no longer
bound to fzf, hatch pointed at the wrong uv.

`test/cases.sh` covers the negative cases, which are the ones that matter: an unset
firewall choice fails the container, `firewall=on` without `NET_ADMIN` fails it, and the
isolation check fails on a writable extra mount, an `ro`-declared-but-`rw`-mounted path,
a forwarded SSH agent, and a mounted runtime socket.

```bash
docker build -t dc-python:test python/
bash test/cases.sh dc-python:test

podman run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e DEVCONTAINER_FIREWALL=off -v "$PWD/test/python:/workspace" \
  dc-python:test \
  bash -c 'sudo -E /usr/local/bin/devcontainer-firewall && bash smoke.sh'
```

Both run in CI on every pull request, alongside the template-source validation and a
`shellcheck` / `zsh -n` lint job.
