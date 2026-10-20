# Per-process Letty wrapper; preserve the original startup file.
[[ -r "$LETTY_ORIGINAL_ZDOTDIR/.zshenv" ]] && source "$LETTY_ORIGINAL_ZDOTDIR/.zshenv"
ZDOTDIR=$LETTY_SHELL_DIR/zsh
