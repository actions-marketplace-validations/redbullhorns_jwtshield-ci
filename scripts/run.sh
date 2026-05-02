#!/usr/bin/env bash
# jwtshield-ci runner. Calls jwtshield API, prints branded status table, sets outputs.
# Per /plan-design DR7: branded ASCII output, color + symbol (color-independent state),
# evidence link. Per DR4: fail-soft mode + 5-min response cache for graceful degradation.

set -uo pipefail

# ---- color helpers ----------------------------------------------------------
if [[ -t 1 ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  C_GREEN=$'\033[0;32m'
  C_RED=$'\033[0;31m'
  C_YELLOW=$'\033[0;33m'
  C_GRAY=$'\033[0;90m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=''
  C_RED=''
  C_YELLOW=''
  C_GRAY=''
  C_BOLD=''
  C_RESET=''
fi

CHECK_PASS="${C_GREEN}✓ PASS${C_RESET}"
CHECK_FAIL="${C_RED}✗ FAIL${C_RESET}"
CHECK_WARN="${C_YELLOW}⚠ WARN${C_RESET}"

# ---- inputs (from action.yml env) -------------------------------------------
API_KEY="${JWTSHIELD_API_KEY:?JWTSHIELD_API_KEY not set}"
ISSUER="${INPUT_ISSUER:?issuer is required}"
AUDIENCE="${INPUT_AUDIENCE:?audience is required}"
ALLOWED_ALGS="${INPUT_ALLOWED_ALGS:-RS256}"
FAIL_ON_SEVERITY="${INPUT_FAIL_ON_SEVERITY:-high}"
FAIL_MODE="${INPUT_FAIL_MODE:-hard}"
ENDPOINT="${INPUT_ENDPOINT:-https://api.jwtshield.com}"
CACHE_TTL="${INPUT_CACHE_TTL_SECONDS:-300}"
TOKEN="${INPUT_TOKEN:-}"

VERSION="1.0.0"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
CACHE_FILE="${RUNNER_TEMP}/jwtshield-ci-cache.json"

# ---- header ----------------------------------------------------------------
printf "%s\n" ""
printf "${C_BOLD}◼ jwtshield-ci v${VERSION}${C_RESET} ─────────────────────────────────\n"

# ---- payload ---------------------------------------------------------------
# Strategy: if a token is provided, run /v1/test/auth-regression with one check.
# If no token, run /v1/lint/oidc-config (config-only audit).

if [[ -n "${TOKEN}" ]]; then
  ENDPOINT_PATH="/v1/test/auth-regression"
  ALGS_JSON=$(printf '%s' "${ALLOWED_ALGS}" | awk -F',' '{
    out="";
    for (i=1; i<=NF; i++) {
      gsub(/^ +| +$/, "", $i);
      out = (out=="" ? "" : out ",") "\"" $i "\"";
    }
    print out;
  }')
  PAYLOAD=$(cat <<JSON
{
  "fail_on_severity": "${FAIL_ON_SEVERITY}",
  "checks": [
    {
      "token": "${TOKEN}",
      "policy": {
        "issuer": "${ISSUER}",
        "audiences": ["${AUDIENCE}"],
        "allowed_algs": [${ALGS_JSON}]
      }
    }
  ]
}
JSON
  )
else
  ENDPOINT_PATH="/v1/lint/oidc-config"
  ALGS_JSON=$(printf '%s' "${ALLOWED_ALGS}" | awk -F',' '{
    out="";
    for (i=1; i<=NF; i++) {
      gsub(/^ +| +$/, "", $i);
      out = (out=="" ? "" : out ",") "\"" $i "\"";
    }
    print out;
  }')
  PAYLOAD=$(cat <<JSON
{
  "issuer": "${ISSUER}",
  "client_id": "ci",
  "audiences": ["${AUDIENCE}"],
  "jwks_uri": "${ISSUER}/.well-known/jwks.json",
  "redirect_uris": [],
  "alg_policy": { "allowed_algs": [${ALGS_JSON}] },
  "https_required": true
}
JSON
  )
fi

# ---- HTTP call -------------------------------------------------------------
HTTP_OUTPUT_FILE=$(mktemp)
HTTP_STATUS=$(curl -sS -o "${HTTP_OUTPUT_FILE}" -w "%{http_code}" \
  -X POST "${ENDPOINT}${ENDPOINT_PATH}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -H "User-Agent: jwtshield-ci/${VERSION}" \
  --max-time 10 \
  --data "${PAYLOAD}" 2>/dev/null) || HTTP_STATUS="000"

# ---- degradation: jwtshield unreachable ------------------------------------
if [[ "${HTTP_STATUS}" =~ ^(000|5[0-9][0-9])$ ]]; then
  printf "  ${C_YELLOW}⚠ jwtshield.com unreachable (HTTP ${HTTP_STATUS})${C_RESET}\n"
  if [[ -f "${CACHE_FILE}" ]] && [[ "${FAIL_MODE}" == "soft" ]]; then
    CACHE_AGE=$(($(date +%s) - $(stat -f %m "${CACHE_FILE}" 2>/dev/null || stat -c %Y "${CACHE_FILE}" 2>/dev/null || echo 0)))
    if [[ "${CACHE_AGE}" -lt "${CACHE_TTL}" ]]; then
      printf "  ${C_GRAY}└ using cached response (age ${CACHE_AGE}s, ttl ${CACHE_TTL}s)${C_RESET}\n"
      cp "${CACHE_FILE}" "${HTTP_OUTPUT_FILE}"
      HTTP_STATUS="200"
    fi
  fi
  if [[ "${HTTP_STATUS}" != "200" ]]; then
    if [[ "${FAIL_MODE}" == "soft" ]]; then
      printf "  ${C_GRAY}└ fail-mode=soft, exiting 0${C_RESET}\n"
      printf "  ─────────────────────────────────────────────────────\n"
      printf "  ${C_YELLOW}DEGRADED${C_RESET} · jwtshield.com unreachable, no fresh cache\n\n"
      echo "status=degraded" >> "${GITHUB_OUTPUT:-/dev/null}"
      echo "findings-count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
      echo "evidence-url=" >> "${GITHUB_OUTPUT:-/dev/null}"
      rm -f "${HTTP_OUTPUT_FILE}"
      exit 0
    fi
    printf "  ${C_RED}└ fail-mode=hard, failing build${C_RESET}\n"
    printf "  Set fail-mode: soft to keep CI green during jwtshield outages.\n\n"
    echo "status=fail" >> "${GITHUB_OUTPUT:-/dev/null}"
    rm -f "${HTTP_OUTPUT_FILE}"
    exit 1
  fi
fi

# ---- 4xx errors (auth / validation) ----------------------------------------
if [[ "${HTTP_STATUS}" =~ ^4[0-9][0-9]$ ]]; then
  if [[ "${HTTP_STATUS}" == "401" ]] || [[ "${HTTP_STATUS}" == "403" ]]; then
    printf "  ${C_RED}✗ AUTH${C_RESET} jwtshield rejected your API key (HTTP ${HTTP_STATUS})\n"
    printf "  Get a fresh key at https://jwtshield.com/signup\n\n"
  else
    printf "  ${C_RED}✗ REQUEST${C_RESET} HTTP ${HTTP_STATUS}\n"
    printf "  Body: %s\n\n" "$(cat "${HTTP_OUTPUT_FILE}" | head -c 500)"
  fi
  echo "status=fail" >> "${GITHUB_OUTPUT:-/dev/null}"
  rm -f "${HTTP_OUTPUT_FILE}"
  exit 1
fi

# ---- success path: parse + cache + render ----------------------------------
cp "${HTTP_OUTPUT_FILE}" "${CACHE_FILE}"

# Parse with jq if present, fall back to grep heuristics.
if command -v jq >/dev/null 2>&1; then
  if [[ -n "${TOKEN}" ]]; then
    SUITE_STATUS=$(jq -r '.suite_status // "unknown"' "${HTTP_OUTPUT_FILE}")
    PASSED=$(jq -r '.passed // 0' "${HTTP_OUTPUT_FILE}")
    FAILED=$(jq -r '.failed // 0' "${HTTP_OUTPUT_FILE}")
    REQUEST_ID=$(jq -r '.request_id // ""' "${HTTP_OUTPUT_FILE}")
    SIG=$(jq -r '.results[0].statuses.signature // "?"' "${HTTP_OUTPUT_FILE}")
    ISS=$(jq -r '.results[0].statuses.issuer // "?"' "${HTTP_OUTPUT_FILE}")
    AUD=$(jq -r '.results[0].statuses.audience // "?"' "${HTTP_OUTPUT_FILE}")
    ALG=$(jq -r '.results[0].statuses.algorithm // "?"' "${HTTP_OUTPUT_FILE}")
    TIM=$(jq -r '.results[0].statuses.time // "?"' "${HTTP_OUTPUT_FILE}")
    CLM=$(jq -r '.results[0].statuses.required_claims // "?"' "${HTTP_OUTPUT_FILE}")
    FINDINGS_COUNT=$(jq -r '.results[0].findings | length' "${HTTP_OUTPUT_FILE}")
    print_check() { local name="$1" val="$2"; local mark="$CHECK_FAIL"; [[ "$val" == "pass" ]] && mark="$CHECK_PASS"; printf "  %-18s %s\n" "${name}:" "${mark}"; }
    print_check "signature" "${SIG}"
    print_check "issuer" "${ISS}"
    print_check "audience" "${AUD}"
    print_check "algorithm" "${ALG}"
    print_check "time" "${TIM}"
    print_check "required_claims" "${CLM}"
  else
    SUITE_STATUS=$(jq -r 'if .valid then "pass" else "fail" end' "${HTTP_OUTPUT_FILE}")
    PASSED=$([[ "${SUITE_STATUS}" == "pass" ]] && echo 1 || echo 0)
    FAILED=$([[ "${SUITE_STATUS}" == "pass" ]] && echo 0 || echo 1)
    REQUEST_ID=""
    FINDINGS_COUNT=$(jq -r '.findings | length' "${HTTP_OUTPUT_FILE}")
    SUMMARY=$(jq -r '.summary // ""' "${HTTP_OUTPUT_FILE}")
    if [[ "${SUITE_STATUS}" == "pass" ]]; then
      printf "  oidc-config-lint:  %s\n" "${CHECK_PASS}"
    else
      printf "  oidc-config-lint:  %s\n" "${CHECK_FAIL}"
    fi
    [[ -n "${SUMMARY}" ]] && printf "  ${C_GRAY}└ %s${C_RESET}\n" "${SUMMARY}"
  fi
else
  SUITE_STATUS="unknown"
  PASSED=0
  FAILED=0
  FINDINGS_COUNT=0
  REQUEST_ID=""
  printf "  ${C_YELLOW}⚠ jq not found on runner; install for richer output.${C_RESET}\n"
fi

printf "  ─────────────────────────────────────────────────────\n"

# ---- print findings if any -------------------------------------------------
if command -v jq >/dev/null 2>&1 && [[ "${FINDINGS_COUNT}" -gt 0 ]]; then
  if [[ -n "${TOKEN}" ]]; then
    jq -r '.results[0].findings[] | "  [31m✗[0m \(.severity | ascii_upcase) [\(.code)] \(.message)\(if .remediation then "\n    └ \(.remediation)" else "" end)"' "${HTTP_OUTPUT_FILE}"
  else
    jq -r '.findings[] | "  [31m✗[0m \(.severity | ascii_upcase) [\(.code)] \(.message)\(if .remediation then "\n    └ \(.remediation)" else "" end)"' "${HTTP_OUTPUT_FILE}"
  fi
  printf "  ─────────────────────────────────────────────────────\n"
fi

# ---- summary line + outputs ------------------------------------------------
TOTAL=$((PASSED + FAILED))
SUMMARY_COLOR="${C_GREEN}"
SUMMARY_LABEL="PASS"
EXIT_CODE=0
if [[ "${SUITE_STATUS}" != "pass" ]]; then
  SUMMARY_COLOR="${C_RED}"
  SUMMARY_LABEL="FAIL"
  EXIT_CODE=1
fi

printf "  %s%s%s · %d/%d checks passed · %s findings\n" \
  "${SUMMARY_COLOR}" "${SUMMARY_LABEL}" "${C_RESET}" \
  "${PASSED}" "${TOTAL}" "${FINDINGS_COUNT}"

if [[ -n "${REQUEST_ID}" ]]; then
  printf "  ${C_GRAY}evidence: https://jwtshield.com/runs/${REQUEST_ID}${C_RESET}\n"
fi
printf "\n"

# Action outputs.
{
  echo "status=${SUMMARY_LABEL,,}"
  echo "findings-count=${FINDINGS_COUNT}"
  if [[ -n "${REQUEST_ID}" ]]; then
    echo "evidence-url=https://jwtshield.com/runs/${REQUEST_ID}"
  else
    echo "evidence-url="
  fi
} >> "${GITHUB_OUTPUT:-/dev/null}"

# Honor fail mode on real failures.
if [[ "${EXIT_CODE}" -ne 0 ]] && [[ "${FAIL_MODE}" == "soft" ]]; then
  printf "  ${C_GRAY}fail-mode=soft, exiting 0 despite ${SUMMARY_LABEL}${C_RESET}\n\n"
  EXIT_CODE=0
fi

rm -f "${HTTP_OUTPUT_FILE}"
exit "${EXIT_CODE}"
