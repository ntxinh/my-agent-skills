#!/usr/bin/env bash
#
# resolve_config.sh — resolve Azure resource config for the azure-monitor skill.
#
# Usage:
#   resolve_config.sh --env <qa|production>
#
# Resolution order:
#   1. <git-root>/.claude/azure-monitor.json   (project-specific override)
#   2. ~/.claude/azure-monitor.json            (personal/global default)
#
# On success: prints the resolved JSON object for the requested environment
# to stdout and exits 0.
#
# On failure (no --env given, invalid env name, or the env isn't defined in
# either file): prints a clear error to stderr and exits 1. The calling
# skill should treat exit 1 as "fall through to the discovery flow", not
# as a reason to guess or invent values.

set -euo pipefail

SKILL_NAME="azure-monitor"
REQUIRED_FIELDS=("subscriptionId" "resourceGroup")

err() { printf 'ERROR: %s\n' "$1" >&2; }

# ---- parse args -------------------------------------------------------
ENV_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="${2:-}"
      shift 2
      ;;
    --env=*)
      ENV_NAME="${1#--env=}"
      shift
      ;;
    *)
      err "Unknown argument: $1"
      echo "Usage: resolve_config.sh --env <qa|production>" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ENV_NAME" ]]; then
  err "No environment specified. Pass --env qa or --env production."
  err "Querying the wrong environment can produce misleading results — ask the user which one before proceeding."
  exit 1
fi

if [[ "$ENV_NAME" != "qa" && "$ENV_NAME" != "production" ]]; then
  err "Invalid environment '$ENV_NAME'. Must be 'qa' or 'production'."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but was not found on PATH."
  exit 1
fi

# ---- locate git root from cwd, if any ---------------------------------
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
  CANDIDATE="$GIT_ROOT/.claude/${SKILL_NAME}.json"
  [[ -f "$CANDIDATE" ]] && PROJECT_CONFIG="$CANDIDATE"
fi

GLOBAL_CONFIG="$HOME/.claude/${SKILL_NAME}.json"
[[ -f "$GLOBAL_CONFIG" ]] || GLOBAL_CONFIG=""

# ---- try a config file for the requested env --------------------------
try_resolve() {
  local file="$1"
  [[ -n "$file" ]] || return 1
  [[ -f "$file" ]] || return 1

  if ! jq -e . "$file" >/dev/null 2>&1; then
    err "Config file is not valid JSON: $file"
    return 1
  fi

  local block
  block="$(jq -c --arg env "$ENV_NAME" 'if has($env) then .[$env] else empty end' "$file" 2>/dev/null || true)"
  [[ -n "$block" && "$block" != "null" ]] || return 1

  # Validate required fields are present and non-empty.
  local missing=()
  for field in "${REQUIRED_FIELDS[@]}"; do
    local val
    val="$(jq -r --arg f "$field" '.[$f] // empty' <<<"$block")"
    [[ -n "$val" ]] || missing+=("$field")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Config for env '$ENV_NAME' in $file is missing required field(s): ${missing[*]}"
    return 1
  fi

  printf '%s' "$block"
  echo "USED_FILE:$file" >&2
  return 0
}

RESOLVED=""
if RESOLVED="$(try_resolve "$PROJECT_CONFIG")"; then
  echo "$RESOLVED"
  exit 0
fi

if RESOLVED="$(try_resolve "$GLOBAL_CONFIG")"; then
  echo "$RESOLVED"
  exit 0
fi

err "No config found for env '$ENV_NAME'."
[[ -n "$PROJECT_CONFIG" ]] && err "Checked project config: $PROJECT_CONFIG (env not present or invalid)"
[[ -z "$PROJECT_CONFIG" ]] && err "No project config found (no .claude/${SKILL_NAME}.json from cwd up to git root)."
[[ -n "$GLOBAL_CONFIG" ]] && err "Checked global config: $GLOBAL_CONFIG (env not present or invalid)" || err "No global config found at ~/.claude/${SKILL_NAME}.json."
err "Fall through to the discovery flow: use read-only 'az ... list' commands to find candidate resources, confirm with the user, and optionally offer to save to the project config."
exit 1
