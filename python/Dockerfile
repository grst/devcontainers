# Python dev container image: uv-first, Python 3.14 by default.
#
#   ghcr.io/grst/devcontainers/python
#
# Layers on the base image, which carries the shell config, CLI tools, Claude Code,
# the egress firewall and the isolation check. Nothing personal belongs here --
# only the Python toolchain.

# Global-scope build args, i.e. declared before any FROM, which is the only place a
# variable may be used in a FROM line.
#
# BASE_REF is a full reference rather than image+tag so CI can pin it to the exact
# digest of the base it just built: a run stays self-consistent even if another run
# publishes a new base halfway through.
ARG BASE_REF=ghcr.io/grst/devcontainers/base:latest
ARG UV_VERSION=0.11.33

# uv arrives as a named stage rather than `COPY --from=ghcr.io/astral-sh/uv:${VERSION}`.
# BuildKit does not expand variables in --from at all ("variable expansion is not
# supported for --from"), while buildah does -- so the inline form built fine under
# podman locally and only failed in CI. A stage works under both.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uvbin

FROM ${BASE_REF}

ARG USERNAME=vscode
ENV DEVCONTAINER_FLAVOUR=python

USER root

# ---------------------------------------------------------------------------
# uv
# ---------------------------------------------------------------------------
COPY --from=uvbin /uv /uvx /usr/local/bin/

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
# 3.14 is the default; 3.13 is here so a `[[tool.hatch.envs.test.matrix]]`-style
# matrix or a project pinning the previous release does not have to download one.
#
# The install dir is owned by the container user so `uv python install 3.12` works
# at runtime as well. Those ad-hoc installs are lost on rebuild (the dir is an
# image layer, not a volume) -- add the version to this line if you need it to
# stick.
ARG PYTHON_VERSIONS="3.14 3.13"
RUN uv python install ${PYTHON_VERSIONS} \
    && chown -R "${USERNAME}:${USERNAME}" /opt/uv \
    && chmod -R a+rX /opt/uv

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
#
# hatch is here alongside uv, not instead of it: uv drives the container's own
# post-create (`uv sync`) and is the default for a project that expresses no
# preference, while a repo whose pyproject.toml defines hatch environments or a
# version matrix works without any extra setup.
RUN uv tool install --no-cache ruff \
    && uv tool install --no-cache prek \
    && uv tool install --no-cache pre-commit \
    && uv tool install --no-cache hatch \
    && uv tool install --no-cache ipython \
    && uv tool install --no-cache zizmor \
    && uv tool install --no-cache cruft \
    && chown -R "${USERNAME}:${USERNAME}" /opt/uv \
    && chmod -R a+rX /opt/uv \
    && ruff --version && prek --version && hatch --version

# Point hatch at the uv already in the image. Left unset, hatch downloads its own
# private copy into its data directory the first time an environment uses
# `installer = "uv"` -- a second uv, on a different release cadence, for no reason.
#
# hatch keeps environments and its managed interpreters under ~/.local/share/hatch,
# which devcontainer.json puts on a named volume. Without that, every rebuild would
# re-create environments and re-download interpreters; it is also why the directory
# must not live in the workspace bind mount, where it would collide with a hatch run
# on the host.
ENV HATCH_ENV_TYPE_VIRTUAL_UV_PATH=/usr/local/bin/uv
RUN mkdir -p "/home/${USERNAME}/.local/share/hatch" \
    && chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.local/share/hatch"

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
ARG TARGETARCH
RUN set -eux; \
    if [ "${TARGETARCH:-amd64}" != 'amd64' ]; then \
        echo "Google publishes no Chrome deb for ${TARGETARCH}; pick a browser for" >&2; \
        echo "this arch before enabling it in .github/workflows/images.yaml." >&2; \
        exit 1; \
    fi; \
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
# isolation boundary. See the README for the screenshot/dump-dom incantations.
# `chromium` is a symlink to it, since that is the name most snippets use.
ENV CHROME_PATH=/usr/bin/google-chrome \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    PLAYWRIGHT_BROWSERS_PATH=/home/${USERNAME}/.cache/ms-playwright

# ---------------------------------------------------------------------------
# Python-specific environment
# ---------------------------------------------------------------------------
# Unbuffered so an agent sees output from a long-running script as it happens
# rather than in one lump at exit.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_CACHE_DIR=/home/${USERNAME}/.cache/uv

USER ${USERNAME}
WORKDIR /workspace
