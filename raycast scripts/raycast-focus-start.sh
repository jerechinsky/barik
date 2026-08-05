#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title focus timer - start
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ⏳
# @raycast.argument1 { "type": "text", "placeholder": "Task name" }
# @raycast.argument2 { "type": "text", "placeholder": "Duration (25, 25m, 1h, 1h30m)" }

TASK="$1"
DURATION="$2"

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
    fi

    echo $seconds
}

SECONDS_VAL=$(parse_duration "$DURATION")

echo "${TASK}|${SECONDS_VAL}" > ~/.barik-focus-timer
