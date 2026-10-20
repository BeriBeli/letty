# Letty semantic prompts; zsh hook arrays preserve existing hooks.
[[ -o interactive ]] || return
(( ${+__letty_installed} )) && return
__letty_installed=1
# Match Ghostty: prompt = abbreviated directory, execution = command line.
__letty_preexec() {
    builtin printf '\033]2;%s\a\033]133;C\a' "${1//[[:cntrl:]]/}"
}
__letty_precmd() {
    local code=$?
    local title=${(%):-%(4~|…/%3~|%~)}
    title=${title//[[:cntrl:]]/}
    local LC_ALL=C p=$PWD encoded='' ch n
    while [[ -n $p ]]; do
        ch=${p[1]}; p=${p[2,-1]}
        case $ch in [a-zA-Z0-9/._~-]) encoded+=$ch;; *) printf -v n '%%%02X' "'$ch"; encoded+=$n;; esac
    done
    builtin printf '\033]2;%s\a\033]133;D;%d\a\033]7;file://localhost%s\a\033]133;A\a' "$title" "$code" "$encoded"
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec __letty_preexec
# Run before other precmd hooks so their exit status cannot replace the command's.
precmd_functions=(__letty_precmd ${precmd_functions:#__letty_precmd})
PROMPT=${PROMPT:-'%m%# '}$'%{\e]133;B\a%}'
