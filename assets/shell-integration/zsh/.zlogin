# Per-process Letty wrapper; preserve the original startup file.
[[ -r "$LETTY_ORIGINAL_ZDOTDIR/.zlogin" ]] && source "$LETTY_ORIGINAL_ZDOTDIR/.zlogin"
source "$LETTY_SHELL_DIR/zsh/finish.zsh"
