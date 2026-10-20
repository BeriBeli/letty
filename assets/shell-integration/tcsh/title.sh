#!/bin/sh
# Arguments stay data. Strip terminal controls before emitting OSC 2.
mode=$1
shift
case $mode in
    prompt)
        directory=$1
        home=$2
        title=$directory
        if [ -n "$home" ]; then
            case $directory in "$home") title='~';; "$home"/*) title="~/${directory#"$home/"}";; esac
        fi
        ;;
    command)
        case ${1-} in letty_title_end:) exit 0;; esac
        title=$*
        ;;
    *) exit 2;;
esac
clean=$(printf '%s' "$title" | LC_ALL=C tr -d '\000-\037\177')
printf '\033]2;%s\007' "$clean"

if [ "$mode" = prompt ]; then
    # Encode every non-slash byte; no shell evaluation of directory contents.
    encoded=$(printf '%s' "$directory" | LC_ALL=C od -An -v -tx1 | LC_ALL=C awk '{for(i=1;i<=NF;i++) if($i=="2f") printf "/"; else printf "%%%s",toupper($i)}')
    printf '\033]7;file://localhost%s\007' "$encoded"
fi
