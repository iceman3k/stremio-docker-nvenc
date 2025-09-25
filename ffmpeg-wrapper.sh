#!/usr/bin/env bash
# Intercepts calls to ffmpeg and removes the problematic flag "-filter_hw_device cu".

REAL_FFMPEG="/usr/bin/ffmpeg"
NEW_ARGS=()
skip_next=0

for arg in "$@"; do
    if (( skip_next )); then
        skip_next=0
        continue
    fi
    if [[ "$arg" == "-filter_hw_device" ]]; then
        skip_next=1   # skip the next argument ("cu")
        continue
    fi
    NEW_ARGS+=("$arg")
done

exec "$REAL_FFMPEG" "${NEW_ARGS[@]}"
