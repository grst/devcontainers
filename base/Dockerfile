# Base dev container image: every personal customization, no language toolchain.
#
#   ghcr.io/grst/devcontainers/base
#
# Language images layer on top of this one (see ../python/Dockerfile). Keeping the
# split means a future rust image inherits the same shell, tools, firewall and
# isolation checks without duplicating any of it.
#
# Every downloaded version is an ARG so `grep ARG base/Dockerfile` lists
# everything that needs bumping.

ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base
# Ubuntu 26.04 LTS "Resolute Raccoon". Pinned to a release tag rather than the
# floating :resolute so a rebuild is reproducible.
ARG BASE_TAG=3.0.3-resolute
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG USERNAME=vscode
ARG TZ=Europe/Berlin
ENV TZ="${TZ}"

# DEVCONTAINER is the marker tooling (including Claude Code) uses to detect that
# it is running in a dev container. DEVCONTAINER_FLAVOUR is ours: it names the
# image in the shell prompt so a container shell is never mistaken for a host one.
ENV DEVCONTAINER=true \
    DEVCONTAINER_FLAVOUR=base

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
# different CLI. TARGETARCH is provided by buildx.
ARG TARGETARCH
ARG YQ_VERSION=v4.53.3
RUN curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
    && chmod 0755 /usr/local/bin/yq \
    && yq --version

# ---------------------------------------------------------------------------
# rga (ripgrep-all): ripgrep across PDFs, docx, sqlite, zip, ...
# ---------------------------------------------------------------------------
ARG RGA_VERSION=v0.10.10
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) rga_triple='x86_64-unknown-linux-musl' ;; \
        arm64) rga_triple='aarch64-unknown-linux-gnu' ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL "https://github.com/phiresky/ripgrep-all/releases/download/${RGA_VERSION}/ripgrep_all-${RGA_VERSION}-${rga_triple}.tar.gz" \
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
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
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
    case "${TARGETARCH}" in \
        amd64) node_arch='x64' ;; \
        arm64) node_arch='arm64' ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${node_arch}.tar.xz" \
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
# Shell configuration
# ---------------------------------------------------------------------------
# Source files are stored undotted in this repo and get their dots here. The
# fragments live in /etc/devcontainer/zsh so they are shared by every user in the
# container and are not shadowed if something copies a ~/.zshrc in.
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
RUN chsh -s /bin/zsh "${USERNAME}"

# bash gets the shared history location too, for the odd `podman exec` that lands
# in it. The zsh config sets its own HISTFILE.
RUN printf '\n# dev container: history on the /commandhistory volume\nexport HISTFILE=/commandhistory/.bash_history\nexport PROMPT_COMMAND="history -a"\n' \
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
# by default, so it warns on every build and has no effect on derived images. The
# login shell is set with chsh above, which does persist.
