# Aliases available in the dev container.
#
# Sourced from zshrc. Only the host aliases that make sense in a container are
# here; see ../../README.md for the omissions.
#
# Note what is NOT here: the host's `cp -iv`, `mv -iv`, `rm -v`, `ln -v`. The -i
# flags make those commands block on stdin, which stalls any non-interactive
# script and, more importantly, hangs an agent running in auto mode on what looks
# like a completed tool call.

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------
alias ls='ls --color=auto --human-readable --group-directories-first --classify'
alias l='ls'
alias ll='ls -lh'
alias la='ls -a'
alias tree='tree -C'

# ---------------------------------------------------------------------------
# Searching
# ---------------------------------------------------------------------------
alias grep='grep --colour=auto'
alias egrep='egrep --colour=auto'
alias cgrep='grep --color=always'   # keep colour when piping into less/fzf

# ---------------------------------------------------------------------------
# Editor
# ---------------------------------------------------------------------------
alias vim='nvim'
alias vi='nvim'

# ---------------------------------------------------------------------------
# Data wrangling
# ---------------------------------------------------------------------------
alias json='jq .'
alias csv='mlr --icsv --opprint cat'
alias tsv='mlr --itsv --opprint cat'
alias tsv2csv="sed -r 's/\t/,/g'"

# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------
alias st='git status'
alias co='git checkout'
alias ga='git add'
alias pu='git push'
alias pull='git pull'
# Re-run the previous command after staging what a pre-commit hook rewrote.
alias rcm='git add -u && fc -s'

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
alias chmox='chmod +x'
alias murder='pkill --signal SIGKILL'
alias diff='diff -Nuar'

# cp, mv, rm and ln are deliberately left unaliased -- plain POSIX behaviour, no
# -i, no -v. Pass the flags explicitly when you want them.
