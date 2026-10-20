# tcsh (including csh linked to tcsh). Source after your existing aliases.
# Does not claim OSC 133 prompt/idle integration.
if (! $?tcsh) goto letty_title_end
if ($?__letty_title_installed) goto letty_title_end
set __letty_title_installed = 1
if (! $?LETTY_SHELL_DIR) then
    echo 'Letty: LETTY_SHELL_DIR is required for tcsh titles.' >& /dev/stderr
    unset __letty_title_installed
    goto letty_title_end
endif
set __letty_saved_precmd = "`alias precmd`"
set __letty_saved_postcmd = "`alias postcmd`"
alias __letty_user_precmd "$__letty_saved_precmd"
alias __letty_user_postcmd "$__letty_saved_postcmd"
alias precmd '/bin/sh "$LETTY_SHELL_DIR/tcsh/title.sh" prompt "$cwd" "$home"; __letty_user_precmd'
unset __letty_saved_precmd __letty_saved_postcmd
alias postcmd '/bin/sh "$LETTY_SHELL_DIR/tcsh/title.sh" command \!#:q; __letty_user_postcmd'
letty_title_end:
