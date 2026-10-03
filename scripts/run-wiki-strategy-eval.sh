#!/usr/bin/env bash
# Live semantic evaluation launcher (plan Phase 5, AC.7).
#
# Usage:
#   scripts/run-wiki-strategy-eval.sh [--scenario <id>] [--keep-fixtures]
#                                     [--budget-seconds N] [--max-tokens N]
#                                     [--max-cost X]
#
# What this script does:
#   1. Resolves the REAL App Group id from WIKI_APP_GROUP_ID (when it is not
#      already set to the eval marker) or signing/local.config, and derives the
#      provider-config directory from it. The config is READ ONLY.
#   2. Builds wikictl + WikiStrategyEvalRunner and stages wikictl at
#      build/wikictl (the helpers directory the agent's PATH prefers).
#   3. Runs WikiStrategyEvalRunner --live. All wiki data goes to disposable
#      fixture databases under tmp/wiki-strategy-eval/<timestamp>/ — never to
#      the App Group container.
#
# The run contacts the configured provider and spends real quota. Read the
# per-scenario report's human rubric before treating a structural PASS as
# semantic success.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${WIKI_APP_GROUP_ID:-}" == *".eval"* ]]; then
  echo "run-wiki-strategy-eval: WIKI_APP_GROUP_ID is set to an eval marker (${WIKI_APP_GROUP_ID}) — unset it so the real provider config can be resolved." >&2
  exit 2
fi

if [[ -n "${WIKI_APP_GROUP_ID:-}" ]]; then
  real_group="${WIKI_APP_GROUP_ID}"
elif [[ -f signing/local.config ]] && grep -q '^APP_GROUP=' signing/local.config; then
  real_group="$(grep '^APP_GROUP=' signing/local.config | cut -d= -f2 | tr -d '\"'"'"'')"
else
  echo "run-wiki-strategy-eval: could not resolve the App Group id. Export WIKI_APP_GROUP_ID=<your group id> or create signing/local.config with APP_GROUP=." >&2
  exit 2
fi

provider_config_dir="$HOME/Library/Group Containers/$real_group"
if [[ ! -f "$provider_config_dir/agent-providers.json" ]]; then
  echo "run-wiki-strategy-eval: no agent-providers.json in $provider_config_dir — configure a provider in the app first (Settings → Providers)." >&2
  exit 2
fi

echo "run-wiki-strategy-eval: provider config (read-only): $provider_config_dir"
swift build --product wikictl
swift build --product WikiStrategyEvalRunner
mkdir -p build
cp -f .build/debug/wikictl build/wikictl

.build/debug/WikiStrategyEvalRunner run --live \
  --provider-config-dir "$provider_config_dir" \
  "$@"
