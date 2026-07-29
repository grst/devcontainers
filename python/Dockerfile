# Dev container image: personal shell setup, CLI tools, Claude Code, the egress
# firewall and the isolation check, plus a uv-first Python 3.14 toolchain.
#
#   ghcr.io/grst/devcontainers/python
#
# amd64 only. Google publishes no Chrome deb for arm64, so the download URLs below
# are hardcoded rather than dispatching on TARGETARCH; add the dispatch back if a
# reason to build arm64 turns up.
#
# Every downloaded version is an ARG so `grep '^ARG' Dockerfile` lists everything
# that needs bumping.

# Ubuntu 26.04 LTS "Resolute Raccoon". Pinned to a release tag rather than the
# floating :resolute so a rebuild is reproducible.
FROM mcr.microsoft.com/devcontainers/base:3.0.3-resolute

ARG USERNAME=vscode
ARG TZ=Europe/Berlin
ENV TZ="${TZ}"

# DEVCONTAINER is the marker tooling (including Claude Code) uses to detect that
# it is running in a dev container. DEVCONTAINER_FLAVOUR is ours: it names the
# image in the shell prompt so a container shell is never mistaken for a host one.
ENV DEVCONTAINER=true \
    DEVCONTAINER_FLAVOUR=python

USER root

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
# Ubuntu 26.04 carries new enough versions of everything the shell config needs,
# which 24.04 did not: fzf 0.67 (>= 0.48, so `fzf --zsh` works and no keybinding
# files have to be vendored) and git-delta 0.18. Only yq and rga still come from
# GitHub releases below.
#
# Upstream devcontainer images have historically shipped a yarn apt source whose
# signing key is absent, which makes every apt-get update fail. Nothing here needs
# yarn, so drop the source if it exists.
RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        # shell
        zsh \
        fzf \
        # search and file tools
        ripgrep \
        fd-find \
        bat \
        tree \
        less \
        # diff and data
        git-delta \
        jq \
        miller \
        # editors
        vim \
        neovim \
        # terminal multiplexing, process inspection
        tmux \
        htop \
        procps \
        psmisc \
        # per-directory environments
        direnv \
        # networking, needed by the firewall and by the allowlist resolution
        iptables \
        ipset \
        dnsutils \
        iproute2 \
        curl \
        wget \
        ca-certificates \
        gnupg \
        # misc
        unzip \
        xz-utils \
        git-lfs \
        locales \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Debian/Ubuntu rename these two to avoid clashes with unrelated packages; put the
# upstream names on PATH because that is what the shell config and muscle memory
# expect.
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -sf "$(command -v batcat)" /usr/local/bin/bat

# UTF-8 throughout, or fzf and delta draw broken box characters.
RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# yq (mikefarah v4)
# ---------------------------------------------------------------------------
# Not the archive's `yq`, which is the unrelated Python kislyuk/yq with a
# different CLI.
ARG YQ_VERSION=v4.53.3
RUN curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod 0755 /usr/local/bin/yq \
    && yq --version

# ---------------------------------------------------------------------------
# rga (ripgrep-all): ripgrep across PDFs, docx, sqlite, zip, ...
# ---------------------------------------------------------------------------
ARG RGA_VERSION=v0.10.10
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    curl -fsSL "https://github.com/phiresky/ripgrep-all/releases/download/${RGA_VERSION}/ripgrep_all-${RGA_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz -C "$tmp" --strip-components=1; \
    install -m 0755 "$tmp"/rga "$tmp"/rga-preproc /usr/local/bin/; \
    rm -rf "$tmp"; \
    rga --version

# ---------------------------------------------------------------------------
# GitHub CLI
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && gh --version

# ---------------------------------------------------------------------------
# Node and Claude Code
# ---------------------------------------------------------------------------
# From the official tarball rather than the node devcontainer feature: the feature
# would run on every container create in every consuming repo, while this is a
# layer they pull once.
ARG NODE_VERSION=v24.18.0
RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
            --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    node --version; \
    npm --version

# Claude Code keeps itself up to date inside the container, so this only has to be
# recent enough to bootstrap. Pin it and set DISABLE_AUTOUPDATER=1 in containerEnv
# if you need reproducible agent behaviour instead.
RUN npm install -g --no-fund --no-audit @anthropic-ai/claude-code \
    && npm cache clean --force \
    && claude --version

# ---------------------------------------------------------------------------
# uv
# ---------------------------------------------------------------------------
# The pinned release tarball, not `COPY --from=ghcr.io/astral-sh/uv:...`. The image
# form needs either a variable in --from, which BuildKit refuses to expand, or an
# extra named stage -- and either way it makes the build depend on a second registry
# to deliver two static binaries. This is also how yq and rga are installed above,
# so pinned binaries follow one pattern rather than two.
ARG UV_VERSION=0.11.33
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        | tar -xz -C "$tmp" --strip-components=1; \
    install -m 0755 "$tmp"/uv "$tmp"/uvx /usr/local/bin/; \
    rm -rf "$tmp"; \
    uv --version

# UV_LINK_MODE=copy because the cache lives on a named volume while projects live
# on the workspace bind mount: hardlinking across those two filesystems fails, and
# uv would otherwise warn on every sync.
ENV UV_LINK_MODE=copy \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin

# ---------------------------------------------------------------------------
# Interpreters
# ---------------------------------------------------------------------------
# 3.14 is the default; 3.13 is here so a version matrix or a project pinning the
# previous release does not have to download one.
#
# The install dir is owned by the container user so `uv python install 3.12` works
# at runtime as well. Those ad-hoc installs are lost on rebuild (the dir is an
# image layer, not a volume) -- add the version to this line if you need it to
# stick.
ARG PYTHON_VERSIONS="3.14 3.13"
RUN uv python install ${PYTHON_VERSIONS}

# Makes a bare `uv venv` / `uv sync` in a project that pins nothing resolve to
# 3.14. A project's own requires-python or .python-version still wins, and the
# devcontainer template exposes this as the pythonVersion option so a consumer can
# override it through containerEnv without rebuilding.
ENV UV_PYTHON=3.14

# `python` on PATH for the many tools that assume it exists, pointed at the
# default interpreter rather than a distro one.
RUN ln -sf "$(uv python find 3.14 2>/dev/null)" /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3 /usr/local/bin/python \
    && python --version

# ---------------------------------------------------------------------------
# Global Python tools
# ---------------------------------------------------------------------------
# Each in its own environment via `uv tool`, with entry points in /usr/local/bin so
# every user in the container can run them and no project venv is polluted.
#
# prek is the Rust reimplementation of pre-commit and is what actually gets used;
# pre-commit itself is here because some repos' hooks invoke it by name.
RUN set -eux; \
    for tool in ruff prek pre-commit hatch ipython zizmor cruft; do \
        uv tool install --no-cache "$tool"; \
    done; \
    chown -R "${USERNAME}:${USERNAME}" /opt/uv; \
    chmod -R a+rX /opt/uv; \
    ruff --version; prek --version; hatch --version

# Point hatch at the uv already in the image; left unset it downloads a second,
# private copy on first use. Its data directory is a named volume (see
# devcontainer.json), so environments and managed interpreters survive a rebuild
# without landing in the workspace.
ENV HATCH_ENV_TYPE_VIRTUAL_UV_PATH=/usr/local/bin/uv

# ---------------------------------------------------------------------------
# Headless browser
# ---------------------------------------------------------------------------
# So an agent can render HTML and look at the result without any extra setup.
#
# Google Chrome, not `apt install chromium`. On Ubuntu, `chromium` and
# `chromium-browser` are transitional *snap* packages -- a 2.4 kB shell script that
# shells out to snapd, which does not exist in a container. apt reports success and
# you are left with no working browser at all. (The Debian-based predecessor of this
# image installed a real chromium deb; that difference is easy to miss when porting.)
#
# Chrome's deb also pulls in the shared libraries Playwright's own build needs, so
# `playwright install chromium` works later without --with-deps.
RUN set -eux; \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg; \
    chmod 0644 /etc/apt/keyrings/google-chrome.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        google-chrome-stable \
        fonts-liberation \
        fonts-noto-color-emoji; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    ln -sf /usr/bin/google-chrome /usr/local/bin/chromium; \
    chromium --version

# --no-sandbox is required when driving it: the browser's own sandbox needs
# privileges this container does not have, and the container is already the
# isolation boundary. `chromium` is a symlink to it, since that is the name most
# snippets use.
ENV CHROME_PATH=/usr/bin/google-chrome \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    PLAYWRIGHT_BROWSERS_PATH=/home/${USERNAME}/.cache/ms-playwright

# Unbuffered so an agent sees output from a long-running script as it happens
# rather than in one lump at exit.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_CACHE_DIR=/home/${USERNAME}/.cache/uv

# ---------------------------------------------------------------------------
# Shell configuration
# ---------------------------------------------------------------------------
# Source files are stored undotted in this repo and get their dots here: Claude
# Code's sandbox denyRead matches on dotfile names, so an undotted source stays
# readable while it is being edited. The fragments live in /etc/devcontainer/zsh so
# they are shared by every user in the container and are not shadowed if something
# copies a ~/.zshrc in.
COPY dotfiles/aliases.zsh dotfiles/functions.zsh dotfiles/fzf.zsh \
        /etc/devcontainer/zsh/
COPY dotfiles/zshrc /etc/skel/.zshrc
COPY dotfiles/zshrc "/home/${USERNAME}/.zshrc"

# System scope, deliberately not ~/.gitconfig: VS Code copies the host's
# ~/.gitconfig in unless dev.containers.copyGitConfig is false, and at system
# scope ours stays a coherent base underneath that copy instead of being replaced
# by it.
COPY dotfiles/gitconfig /etc/gitconfig

RUN chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.zshrc" \
    && chmod 0644 /etc/gitconfig /etc/skel/.zshrc /etc/devcontainer/zsh/*.zsh

# The upstream image leaves the user's login shell as bash, so a plain
# `podman exec -it <container>` would land in bash and load none of the above.
# (`devcontainer exec ... zsh` and VS Code's terminal profile ask for zsh
# explicitly, so those were fine either way -- this is for everything else.)
#
# bash gets the shared history location too, for the odd `podman exec` that lands
# in it. The zsh config sets its own HISTFILE.
RUN chsh -s /bin/zsh "${USERNAME}" \
    && printf '\n# dev container: history on the /commandhistory volume\nexport HISTFILE=/commandhistory/.bash_history\nexport PROMPT_COMMAND="history -a"\n' \
        >> /etc/bash.bashrc

# ---------------------------------------------------------------------------
# Firewall, isolation check, status line
# ---------------------------------------------------------------------------
COPY bin/devcontainer-firewall bin/devcontainer-isolation /usr/local/bin/
COPY bin/statusline.sh /usr/local/share/devcontainer/statusline.sh
COPY etc/firewall-allowlist.txt /etc/devcontainer/firewall-allowlist.d/00-base.txt
COPY etc/mount-allowlist.txt /etc/devcontainer/mount-allowlist.txt

RUN chmod 0755 /usr/local/bin/devcontainer-firewall \
        /usr/local/bin/devcontainer-isolation \
        /usr/local/share/devcontainer/statusline.sh \
    && chmod 0644 /etc/devcontainer/mount-allowlist.txt \
        /etc/devcontainer/firewall-allowlist.d/00-base.txt

# postStartCommand runs both of these through sudo. env_keep is required because
# sudo scrubs the environment by default and both scripts are configured through
# it -- without this, DEVCONTAINER_FIREWALL would always look unset and the gate
# would fire on every start.
# SSH_AUTH_SOCK is in env_keep so the isolation check can see a forwarded agent: it
# cannot read the container user's /proc/<pid>/environ instead, because under rootless
# podman the container root is a mapped subuid with no privilege over that user.
RUN printf '%s\n' \
        'Defaults env_keep += "DEVCONTAINER_FIREWALL DEVCONTAINER_EXTRA_MOUNTS DEVCONTAINER_FLAVOUR SSH_AUTH_SOCK"' \
        "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/devcontainer-firewall, /usr/local/bin/devcontainer-isolation" \
        > /etc/sudoers.d/devcontainer \
    && chmod 0440 /etc/sudoers.d/devcontainer \
    && visudo -cf /etc/sudoers.d/devcontainer

# ---------------------------------------------------------------------------
# Volume mount points
# ---------------------------------------------------------------------------
# Created and chowned up front so podman seeds the named volumes with the right
# ownership. Without this the volumes come up owned by root and the container user
# cannot write to them.
RUN mkdir -p \
        "/home/${USERNAME}/.claude" \
        "/home/${USERNAME}/.cache" \
        "/home/${USERNAME}/.local/share/uv" \
        "/home/${USERNAME}/.local/share/hatch" \
        /commandhistory \
        /workspace \
    && touch /commandhistory/.zsh_history /commandhistory/.bash_history \
    && chown -R "${USERNAME}:${USERNAME}" \
        "/home/${USERNAME}/.claude" \
        "/home/${USERNAME}/.cache" \
        "/home/${USERNAME}/.local" \
        /commandhistory \
        /workspace

USER ${USERNAME}
WORKDIR /workspace

# No SHELL directive: it is not persisted in the OCI image format that podman writes
# by default, so it warns on every build and has no effect. The login shell is set
# with chsh above, which does persist.
