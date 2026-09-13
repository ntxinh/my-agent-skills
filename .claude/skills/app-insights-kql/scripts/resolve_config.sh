#!/usr/bin/env bash
# resolve_config.sh
#
# Resolves App Insights config for the given environment.
#
# Priority order:
#   1. <repo-root>/.claude/app-insights-kql.json  (project-specific override)
#   2. ~/.claude/app-insights-kql.json             (personal/global default)
#
# Usage:
#   bash scripts/resolve_config.sh --env <qa|production>
#
# Output: resolved config as JSON on stdout (exit 0) on success.
#         Error message on stderr and exit 1 if nothing usable was found.

set -euo pipefail

ENV_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$ENV_NAME" ]]; then
  echo "Missing --env <qa|production>. Ask the user which environment to query before resolving config." >&2
  exit 2
fi

# Normalize to lowercase to match JSON keys (qa / production)
ENV_NAME="$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]')"

find_project_config() {
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.claude/app-insights-kql.json" ]]; then
      echo "$dir/.claude/app-insights-kql.json"
      return 0
    fi
    if [[ -d "$dir/.git" ]]; then
      break
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

REQUIRED_FIELDS=(appInsightsName resourceGroup)

try_resolve_from() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  jq empty "$file" >/dev/null 2>&1 || { echo "File $file is not valid JSON." >&2; return 1; }

  local block
  block=$(jq --arg env "$ENV_NAME" '.[$env] // empty' "$file")
  [[ -z "$block" || "$block" == "null" ]] && return 1

  local missing=""
  for f in "${REQUIRED_FIELDS[@]}"; do
    val=$(echo "$block" | jq -r --arg f "$f" '.[$f] // ""')
    [[ -z "$val" ]] && missing="$missing $f"
  done
  if [[ -n "$missing" ]]; then
    echo "Env '$ENV_NAME' in $file is missing required field(s):$missing" >&2
    return 1
  fi

  echo "$block" | jq --arg source "$file" --arg env "$ENV_NAME" '. + {source: $source, env: $env}'
  return 0
}

PROJECT_CONFIG="$(find_project_config || true)"

if [[ -n "$PROJECT_CONFIG" ]] && try_resolve_from "$PROJECT_CONFIG"; then
  exit 0
fi

GLOBAL_CONFIG="$HOME/.claude/app-insights-kql.json"
if try_resolve_from "$GLOBAL_CONFIG"; then
  exit 0
fi

echo "Could not resolve config for env '$ENV_NAME' from project (.claude/app-insights-kql.json) or ~/.claude/app-insights-kql.json. Run the discovery flow (SKILL.md section 0.1)." >&2
exit 1
