#!/bin/bash
# ~/.claude/hooks/notify-gchat.sh
# Send Google Chat notifications when Claude Code needs input from you. (Notification event)

WEBHOOK_URL="${GCHAT_WEBHOOK_URL:-PLACEHOLDER_DEFAULT_VALUE}"

INPUT=$(cat)n
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude Code requires you to confirm/enter something."')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

PAYLOAD=$(jq -n \
  --arg text "🤖 *Claude Code* needs your input
${MESSAGE}
📁 \`${CWD}\`" \
  '{text: $text}')

curl -s -X POST \
  -H "Content-Type: application/json; charset=UTF-8" \
  "$WEBHOOK_URL" \
  -d "$PAYLOAD" > /dev/null

exit 0
