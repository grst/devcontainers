# fzf integration.
#
# Sourced last from zshrc, because `fzf --zsh` rebinds ^R to its own history
# widget and we want that to win over zsh's history-incremental-search.
#
# Bindings this sets up:
#   ^R  fuzzy history search
#   ^T  fuzzy file/directory picker (fd-backed, see below)
#   M-c fuzzy cd

# fd rather than find, so .gitignore is respected and hidden files are included
# without dragging in .git itself.
export FZF_CTRL_T_COMMAND='fd --hidden --follow --exclude .git .'
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git .'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range :200 {} 2>/dev/null || tree -C {} | head -200'"

# Use fd for **<TAB> path and directory completion too.
_fzf_compgen_path() {
    fd --hidden --follow --exclude .git . "$1"
}
_fzf_compgen_dir() {
    fd --type d --hidden --follow --exclude .git . "$1"
}

# `fzf --zsh` emits key bindings and completion in one go; it needs fzf >= 0.48
# and Ubuntu 26.04 ships 0.67. Fall back to the packaged scripts just in case the
# base image ever moves to an older distro.
if fzf --zsh >/dev/null 2>&1; then
    eval "$(fzf --zsh)"
else
    for _fzf_file in /usr/share/doc/fzf/examples/key-bindings.zsh \
                     /usr/share/doc/fzf/examples/completion.zsh; do
        [[ -r "$_fzf_file" ]] && source "$_fzf_file"
    done
    unset _fzf_file
fi
