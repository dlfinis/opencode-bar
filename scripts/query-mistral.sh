#!/bin/bash
# Query Mistral Vibe (primary) and API budget usage.

set -euo pipefail

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: Required command not found: $command_name" >&2
        exit 1
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_auth_key() {
    local auth_file="$1"
    local key

    [[ -r "$auth_file" ]] || return 1
    key="$(jq -er '.mistral.key | strings | select(length > 0)' "$auth_file" 2>/dev/null)" || return 1
    key="$(trim "$key")"
    [[ -n "$key" ]] || return 1
    printf '%s' "$key"
}

resolve_api_key() {
    local key
    local auth_file
    local auth_files=()

    key="$(trim "${MISTRAL_API_KEY:-}")"
    if [[ -n "$key" ]]; then
        printf '%s' "$key"
        return 0
    fi

    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        auth_files+=("$XDG_DATA_HOME/opencode/auth.json")
    fi
    auth_files+=("$HOME/.local/share/opencode/auth.json")
    auth_files+=("$HOME/Library/Application Support/opencode/auth.json")

    for auth_file in "${auth_files[@]}"; do
        if key="$(read_auth_key "$auth_file")"; then
            printf '%s' "$key"
            return 0
        fi
    done

    return 1
}

require_command curl
require_command jq

if ! API_KEY="$(resolve_api_key)"; then
    echo "Error: Mistral API key not found; set MISTRAL_API_KEY or add mistral.key to OpenCode auth.json" >&2
    exit 1
fi

if ! RESPONSE="$(curl --silent --show-error --fail \
    "https://api.mistral.ai/v1/billing/budget" \
    -H "x-api-key: $API_KEY" \
    -H "Accept: application/json")"; then
    echo "Error: Failed to fetch Mistral billing budget" >&2
    exit 1
fi

if ! ROWS="$(jq -er '
    def numeric:
      if type == "number" then .
      elif type == "string" then (try tonumber catch error("invalid numeric value"))
      else error("expected a numeric value")
      end;

    def row($label; $budget):
      if $budget == null then
        [$label, "", "", "", "", ""] | @tsv
      elif ($budget | type) != "object" then
        error("budget must be an object")
      else
        ($budget.usage_percentage | numeric) as $percent
        | ($budget.initial_budget | numeric) as $limit
        | [$label, ($percent | tostring), (($limit * $percent / 100) | tostring), ($limit | tostring), ($budget.currency // "Unknown"), ($budget.reset_at // "unavailable")] | @tsv
      end;

    if (.vibe_budget | type) != "object" and (.api_budget | type) != "object" then
      error("missing vibe_budget and api_budget")
    else
      [row("Vibe"; .vibe_budget), row("API"; .api_budget)][]
    end
  ' <<< "$RESPONSE")"; then
    echo "Error: Mistral returned an invalid billing budget response" >&2
    exit 1
fi

# Keep percentage and budget formatting stable across user locales.
export LC_ALL=C

while IFS=$'\t' read -r label percentage used limit currency reset_at; do
    if [[ -z "$percentage" ]]; then
        printf '%s Budget: unavailable\n' "$label"
        continue
    fi

    printf '%s Budget: %.1f%% used, %s %.2f / %.2f; reset_at: %s\n' \
        "$label" "$percentage" "$currency" "$used" "$limit" "$reset_at"
done <<< "$ROWS"
