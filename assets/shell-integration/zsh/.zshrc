# Per-process Letty wrapper; preserve the original startup file.
[[ -r "$LETTY_ORIGINAL_ZDOTDIR/.zshrc" ]] && source "$LETTY_ORIGINAL_ZDOTDIR/.zshrc"
# Linux starts an interactive non-login shell; there is no .zlogin stage.
if [[ ! -o login ]]; then source "$LETTY_SHELL_DIR/zsh/finish.zsh"; fi
