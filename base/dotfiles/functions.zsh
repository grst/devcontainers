# Shell functions and prompt plumbing for the dev container.
#
# Sourced from zshrc.

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
# cd and immediately list, the way `c` works on the host.
c() {
    cd "$1" && ls -lh
}

# Replace the current shell, picking up edits to the rc files.
reload() {
    exec "${SHELL}" "$@"
}

# printf %q a pasted path so it survives being passed as a single argument.
escape() {
    local input
    printf 'String to escape: '
    read -r input
    printf '%q\n' "$input"
}

# ---------------------------------------------------------------------------
# Full-text search across every file type rga understands (PDFs, docx, zip, ...)
# ---------------------------------------------------------------------------
# The host version ends in `xdg-open`; there is no desktop here, so it opens the
# hit in $EDITOR instead.
rga-fzf() {
    local rg_prefix='rga --files-with-matches' file
    file="$(
        FZF_DEFAULT_COMMAND="$rg_prefix ${(q)1}" \
            fzf --sort \
                --preview="[[ ! -z {} ]] && rga --pretty --context 5 {q} {}" \
                --phony -q "$1" \
                --bind "change:reload:$rg_prefix {q}" \
                --preview-window='70%:wrap'
    )" && [[ -n "$file" ]] && "${EDITOR}" "$file"
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
# Split across chpwd and precmd so the (relatively expensive) worktree lookup
# only runs when the directory changes, while the dirty marker stays current.

_dc_git_check_worktree() {
    if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == 'true' ]]; then
        git_pwd_is_worktree='true'
        git_worktree_is_bare="$(git config core.bare)"
    else
        git_pwd_is_worktree='false'
        unset git_branch git_worktree_is_bare
    fi
}

_dc_git_branch() {
    git_branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
    git_branch="${git_branch:-detached}"
}

_dc_git_dirty() {
    if [[ "${git_worktree_is_bare}" != 'true' ]] \
        && [[ -n "$(git status --untracked-files=no --porcelain 2>/dev/null)" ]]; then
        git_dirty='%F{green}*'
    else
        unset git_dirty
    fi
}

# Terminal title: user@host:path, plus the running command while one executes.
_dc_termtitle() {
    case "$TERM" in
        xterm*|rxvt*|screen*|tmux*|alacritty|foot|kitty*)
            local path="${(%):-%~}"
            case "$1" in
                precmd)  printf '\e]0;%s\a' "${path}" ;;
                preexec) printf '\e]0;%s [%s]\a' "$2" "${path}" ;;
            esac
            ;;
    esac
}

precmd() {
    _dc_termtitle precmd
    if [[ "${git_pwd_is_worktree}" == 'true' ]]; then
        _dc_git_branch
        _dc_git_dirty
        git_prompt=" %F{blue}[%F{253}${git_branch}${git_dirty}%F{blue}]"
    else
        unset git_prompt
    fi
}

preexec() {
    _dc_termtitle preexec "${(V)1}"
}

chpwd() {
    _dc_git_check_worktree
}

# Run once so the first prompt in a shell already knows about the repo.
_dc_git_check_worktree
