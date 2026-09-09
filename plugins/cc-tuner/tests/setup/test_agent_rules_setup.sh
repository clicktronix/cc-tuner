#!/usr/bin/env bash
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$(dirname "$0")/test_agent_rules_setup.py" "$PLUGIN/scripts/agent-rules-setup.py"
