#!/bin/bash
# Focus Timer for Barik
# Usage:
#   focus-timer.sh "Task Name" 25m   — start a timer
#   focus-timer.sh toggle            — pause or resume
#   focus-timer.sh pause
#   focus-timer.sh resume
#   focus-timer.sh complete
#   focus-timer.sh cancel
# Duration formats: 25m, 1h, 1h30m, 90s

CMD="$1"

# Control commands
case "$CMD" in
    toggle|pause|resume|complete|cancel)
        echo "$CMD" > ~/.barik-focus-timer-cmd
        echo "Focus timer: $CMD"
        exit 0
        ;;
esac

# Start a new timer
TASK="$1"
DURATION="$2"

if [ -z "$TASK" ] || [ -z "$DURATION" ]; then
    echo "Usage:"
    echo "  focus-timer.sh \"Task Name\" 25m   — start a timer"
    echo "  focus-timer.sh toggle            — pause or resume"
    echo "  focus-timer.sh pause / resume / complete / cancel"
    echo "Duration formats: 25m, 1h, 1h30m, 90s"
    exit 1
fi

parse_duration() {
    local d="$1"
    local seconds=0

    if [[ "$d" =~ ^([0-9]+)h([0-9]+)m([0-9]+)s$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]} ))
    elif [[ "$d" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 ))
    elif [[ "$d" =~ ^([0-9]+)h$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$d" =~ ^([0-9]+)m([0-9]+)s$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]} ))
    elif [[ "$d" =~ ^([0-9]+)m$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$d" =~ ^([0-9]+)s$ ]]; then
        seconds=${BASH_REMATCH[1]}
    elif [[ "$d" =~ ^([0-9]+)$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 60 ))
    else
        echo "Invalid duration format: $d"
        echo "Valid formats: 25m, 1h, 1h30m, 90s"
        exit 1
    fi

    echo $seconds
}

SECONDS_VAL=$(parse_duration "$DURATION")

if [ "$SECONDS_VAL" -eq 0 ]; then
    echo "Duration must be greater than 0"
    exit 1
fi

echo "${TASK}|${SECONDS_VAL}" > ~/.barik-focus-timer
echo "Focus timer started: \"$TASK\" for $DURATION (${SECONDS_VAL}s)"
