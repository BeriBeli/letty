# Restore the user environment before installing per-session hooks.
if [[ $LETTY_ZDOTDIR_SET == 1 ]]; then export ZDOTDIR=$LETTY_ORIGINAL_ZDOTDIR; else unset ZDOTDIR; fi
unset LETTY_ZDOTDIR_SET LETTY_ORIGINAL_ZDOTDIR
source "$LETTY_SHELL_DIR/zsh/hooks.zsh"
unset LETTY_SHELL_DIR
