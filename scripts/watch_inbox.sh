#!/bin/bash
# File inbox watcher - monitors .agent_runs/*/feedback_inbox.md for user replies
# Usage: ./scripts/watch_inbox.sh [run_id]

set -euo pipefail

RUN_DIR="${1:-.agent_runs}"
CHECK_INTERVAL="${EXPERIMENT_GRILL_CHECK_INTERVAL:-30}"  # seconds

echo "=== Experiment Grill File Inbox Watcher ==="
echo "Watching: $RUN_DIR"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Press Ctrl+C to stop"
echo

# Initialize state tracking
declare -A last_mtime

while true; do
  # Find all feedback_inbox.md files
  while IFS= read -r -d '' inbox; do
    run_id=$(dirname "$inbox" | xargs basename)

    # Get current mtime
    current_mtime=$(stat -c %Y "$inbox" 2>/dev/null || echo 0)

    # Check if file was modified since last check
    if [[ -z "${last_mtime[$inbox]:-}" ]]; then
      # First time seeing this file
      last_mtime[$inbox]=$current_mtime
      continue
    fi

    if [[ $current_mtime -gt ${last_mtime[$inbox]} ]]; then
      # File was modified!
      echo "[$(date '+%H:%M:%S')] 📝 Feedback received in run: $run_id"

      # Extract decision
      if decision=$(grep "^DECISION:" "$inbox" 2>/dev/null | head -1); then
        echo "  Decision: ${decision#DECISION: }"

        # Extract reasoning if present
        if reasoning=$(grep "^REASONING:" "$inbox" 2>/dev/null | head -1); then
          echo "  Reasoning: ${reasoning#REASONING: }"
        fi

        # Create a flag file for the agent to detect
        touch "$(dirname "$inbox")/feedback_arrived.flag"
        echo "  ✓ Flag created: feedback_arrived.flag"
      else
        echo "  ⚠️  File modified but no DECISION: line found"
      fi

      # Update tracked mtime
      last_mtime[$inbox]=$current_mtime
    fi

  done < <(find "$RUN_DIR" -name "feedback_inbox.md" -print0 2>/dev/null)

  sleep "$CHECK_INTERVAL"
done
