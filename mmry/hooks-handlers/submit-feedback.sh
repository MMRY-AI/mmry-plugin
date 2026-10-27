#!/usr/bin/env bash
# submit-feedback.sh — Submit feedback (bug or feature request) via MMRY AI API.
# Usage: bash submit-feedback.sh --type T --title T --description D [options]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Parse arguments
TYPE="" TITLE="" DESCRIPTION="" COMPONENT="" REPRO_STEPS="" ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)         TYPE="$2"; shift 2 ;;
        --title)        TITLE="$2"; shift 2 ;;
        --description)  DESCRIPTION="$2"; shift 2 ;;
        --component)    COMPONENT="$2"; shift 2 ;;
        --repro-steps)  REPRO_STEPS="$2"; shift 2 ;;
        --environment)  ENVIRONMENT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Validate required fields
if [[ -z "$TYPE" || -z "$TITLE" || -z "$DESCRIPTION" ]]; then
    echo "Error: --type, --title, and --description are required" >&2
    exit 1
fi

if mmry_submit_feedback "$TYPE" "$TITLE" "$DESCRIPTION" \
    "$COMPONENT" "$REPRO_STEPS" "$ENVIRONMENT"; then
    echo "Feedback submitted."
else
    _mmry_print_error "feedback"
    exit 1
fi
