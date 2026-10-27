#!/usr/bin/env bash
set -euo pipefail

[[ "${CARD_KEY:-}" =~ ^B20-[0-9]+$ ]] || { echo "card-review: invalid CARD_KEY '${CARD_KEY:-}'"; exit 1; }

# An empty secret still arrives as an empty env var, which Claude Code would treat as a bad credential
[ -n "${ANTHROPIC_API_KEY:-}" ] || unset ANTHROPIC_API_KEY
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || unset CLAUDE_CODE_OAUTH_TOKEN

JIRA="https://api.atlassian.com/ex/jira/$JIRA_CLOUD_ID/rest/api"
AUTH="$JIRA_EMAIL:$JIRA_API_TOKEN"
WORK=".card-review/$CARD_KEY"
mkdir -p "$WORK/attachments"

echo "card-review: fetching $CARD_KEY"
curl -sf --max-time 30 -u "$AUTH" \
  "$JIRA/3/issue/$CARD_KEY?fields=summary,description,issuetype,priority,status,labels,reporter,created,attachment,issuelinks,parent" \
  > "$WORK/card.json"
jq '{key, summary: .fields.summary, status: .fields.status.name}' "$WORK/card.json"

jq -r '.fields.attachment[]? | select(.mimeType | startswith("image/")) | "\(.id) \(.filename)"' "$WORK/card.json" \
  | head -n 5 \
  | while read -r id name; do
      curl -sfL --max-time 60 -u "$AUTH" "$JIRA/3/attachment/content/$id" \
        -o "$WORK/attachments/${id}-${name//[^A-Za-z0-9._-]/_}"
    done

echo "card-review: reviewing with Claude"
env -u JIRA_API_TOKEN -u JIRA_EMAIL \
  claude -p "$(cat ci/card-review/prompt.md)

Card folder: $WORK" \
    --model "${CARD_REVIEW_MODEL:-sonnet}" \
    --allowedTools "Read,Grep,Glob" \
    --max-turns 20 \
  > "$WORK/review.txt"

[ -s "$WORK/review.txt" ] || { echo "card-review: empty review, not posting"; exit 1; }
cat "$WORK/review.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## Card review: $CARD_KEY"; echo '```'; cat "$WORK/review.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${POST_COMMENT:-false}" != "true" ]; then
  echo "card-review: dry run, not posting to Jira"
  exit 0
fi

jq -n --rawfile body "$WORK/review.txt" '{body: $body}' \
  | curl -sf --max-time 30 -u "$AUTH" -H 'Content-Type: application/json' \
      -X POST --data @- "$JIRA/2/issue/$CARD_KEY/comment" > /dev/null

curl -sf --max-time 30 -u "$AUTH" -H 'Content-Type: application/json' -X PUT \
  --data '{"update":{"labels":[{"add":"ai-reviewed"}]}}' \
  "$JIRA/3/issue/$CARD_KEY" > /dev/null

echo "card-review: posted to $CARD_KEY"
