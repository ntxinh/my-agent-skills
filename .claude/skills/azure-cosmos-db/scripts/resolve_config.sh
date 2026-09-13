#!/usr/bin/env bash
# resolve_config.sh — resolve azure-cosmos-db config for a given environment.
#
# Usage:
#   resolve_config.sh --env <qa|production>
#
# Resolution order:
#   1. Project override: walk up from $PWD to the nearest git root, then
#      <git-root>/.claude/azure-cosmos-db.json
#   2. Personal/global default: ~/.claude/azure-cosmos-db.json
#   3. If neither file defines the requested environment, fail (exit 1).
#      Caller (Claude) should fall through to the discovery flow described
#      in SKILL.md — never guess or fabricate values.
#
# On success: prints the resolved JSON object for that environment to stdout, exit 0.
# On failure: prints a human-readable error to stderr, exit non-zero.
#
# Exit codes:
#   0  resolved successfully
#   1  no config found for the requested environment (-> discovery flow)
#   2  usage error (missing/invalid --env, missing jq, etc.)

set -euo pipefail

SKILL_NAME="azure-cosmos-db"
# Required for the core "establish account context" command (az cosmosdb show).
# databaseName/containerName are only needed for container-scoped steps
# (config/throughput checks, direct queries) and can be supplied later or
# discovered per-investigation, so they're optional here.
REQUIRED_FIELDS=(subscriptionId resourceGroup accountName)
OPTIONAL_DEFAULTS='{}'

usage() {
  echo "Usage: $0 --env <qa|production>" >&2
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found on PATH." >&2
  exit 2
fi

ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument '$1'." >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$ENV" ]]; then
  echo "ERROR: --env is required and was not provided. Ask the user whether they mean 'qa' or 'production' before proceeding." >&2
  usage
  exit 2
fi

if [[ "$ENV" != "qa" && "$ENV" != "production" ]]; then
  echo "ERROR: --env must be 'qa' or 'production' (got '$ENV')." >&2
  usage
  exit 2
fi

# --- locate config files ---------------------------------------------------

find_git_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_CONFIG=""
if GIT_ROOT="$(find_git_root)"; then
  candidate="$GIT_ROOT/.claude/${SKILL_NAME}.json"
  [[ -f "$candidate" ]] && PROJECT_CONFIG="$candidate"
fi

GLOBAL_CONFIG="$HOME/.claude/${SKILL_NAME}.json"
[[ -f "$GLOBAL_CONFIG" ]] || GLOBAL_CONFIG=""

# --- try to resolve the requested env from a given file ---------------------

resolve_from() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 1
  jq -e --arg env "$ENV" 'has($env)' "$file" >/dev/null 2>&1 || return 1
  jq -c --arg env "$ENV" '.[$env]' "$file"
}

RESOLVED=""
SOURCE=""

if RESOLVED="$(resolve_from "$PROJECT_CONFIG")" && [[ -n "$RESOLVED" && "$RESOLVED" != "null" ]]; then
  SOURCE="$PROJECT_CONFIG"
elif RESOLVED="$(resolve_from "$GLOBAL_CONFIG")" && [[ -n "$RESOLVED" && "$RESOLVED" != "null" ]]; then
  SOURCE="$GLOBAL_CONFIG"
else
  echo "ERROR: No config found for environment '$ENV'." >&2
  echo "  Project config checked: ${PROJECT_CONFIG:-<none found>}" >&2
  echo "  Global config checked:  ${GLOBAL_CONFIG:-<none found>}" >&2
  echo "Fall through to the discovery flow in SKILL.md (do not guess values)." >&2
  exit 1
fi

# --- validate required fields ------------------------------------------------

MISSING=()
for field in "${REQUIRED_FIELDS[@]}"; do
  val="$(jq -r --arg f "$field" '.[$f] // empty' <<<"$RESOLVED")"
  [[ -z "$val" ]] && MISSING+=("$field")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Config for '$ENV' in $SOURCE is missing required field(s): ${MISSING[*]}" >&2
  echo "Required fields: ${REQUIRED_FIELDS[*]}" >&2
  exit 1
fi

# --- apply defaults for optional fields, then emit ---------------------------

RESOLVED="$(jq -c --argjson defaults "$OPTIONAL_DEFAULTS" '$defaults + .' <<<"$RESOLVED")"

echo "$RESOLVED"
exit 0
