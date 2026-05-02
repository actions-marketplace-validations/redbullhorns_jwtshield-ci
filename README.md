# jwtshield-ci

> **Catch silent JWT bugs before prod.** CI auth regression tests + JWKS rotation drift detection. Add 5 lines to your GitHub Actions workflow.

```yaml
- uses: redbullhorns/jwtshield-ci@v1
  with:
    issuer: https://login.example.com
    audience: api://backend
    fail-on-severity: high
    api-key: ${{ secrets.JWTSHIELD_API_KEY }}
```

That's it. The Action calls jwtshield's regression suite with your policy, prints a structured status table, and fails the build on any high-severity finding.

## What this catches

| Failure mode | Status quo | jwtshield-ci |
|---|---|---|
| JWKS rotation without overlap | 3am page when keys rotate | Caught at PR-time |
| Wrong audience claim | Token accepted by the wrong service | Regression test fails the PR |
| OIDC config drift | Stale issuer / JWKS URI / alg policy | Lint emits structured remediation |
| `alg=none` and confused-deputy attacks | "We have a verifier somewhere" | Explicit allowlist enforcement |

Read the full incident class catalogue: [Three JWT bugs that ship to prod silently](https://jwtshield.com/blog/3-jwt-bugs-that-ship-to-prod-silently).

## Sample CI output

```
◼ jwtshield-ci v1.0.0 ─────────────────────────────────
  signature:        ✓ PASS
  issuer:           ✓ PASS
  audience:         ✓ PASS
  algorithm:        ✓ PASS
  time:             ✓ PASS
  required_claims:  ✓ PASS
  ─────────────────────────────────────────────────────
  PASS · 1/1 checks passed · 0 findings
  evidence: https://jwtshield.com/runs/abc123def456
```

On failure, each finding includes a code, severity, message, and remediation hint.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-key` | yes | — | jwtshield API key. Get one at [jwtshield.com/signup](https://jwtshield.com/signup). Recommended: `${{ secrets.JWTSHIELD_API_KEY }}`. |
| `issuer` | yes | — | Expected token issuer URL (e.g. `https://login.example.com`). |
| `audience` | yes | — | Expected `aud` claim (e.g. `api://backend`). |
| `allowed-algs` | no | `RS256` | Comma-separated allowed signature algorithms. Never include `none`. |
| `fail-on-severity` | no | `high` | `low` / `medium` / `high` / `critical`. Findings at or above fail the build. |
| `fail-mode` | no | `hard` | `hard` (default): fail on jwtshield outage. `soft`: warn-only, do not block. |
| `endpoint` | no | `https://api.jwtshield.com` | Override only for staging / self-host. |
| `cache-ttl-seconds` | no | `300` | How long to serve the last successful response during outages (soft mode). |
| `token` | no | (lint-only) | Optional JWT to validate. **Use synthetic test tokens, never production tokens.** If omitted, runs the OIDC config lint. |

## Outputs

| Output | Description |
|---|---|
| `status` | Overall result: `pass`, `fail`, `warn`, or `degraded`. |
| `findings-count` | Number of findings emitted at any severity. |
| `evidence-url` | Public URL of the audit-trail entry. Empty when degraded/cached. |

## Fail modes

**Hard mode (default).** If jwtshield.com is unreachable, the CI job fails. Use this when auth correctness is a release gate.

**Soft mode.** When `fail-mode: soft`, transient jwtshield outages serve the last cached response (within `cache-ttl-seconds`) or warn and exit 0. Use this when you do not want jwtshield outages to block your deploys.

```yaml
- uses: redbullhorns/jwtshield-ci@v1
  with:
    issuer: https://login.example.com
    audience: api://backend
    fail-on-severity: high
    fail-mode: soft  # do not block CI on jwtshield outages
    cache-ttl-seconds: 600
    api-key: ${{ secrets.JWTSHIELD_API_KEY }}
```

## Trust posture

- **Synthetic tokens only.** Generate test tokens against your issuer with a test signing key. We do not need or want production tokens.
- **Zero retention.** Tokens are validated in memory and discarded. We log structured metadata for the audit trail, never the bearer token.
- **Audit evidence.** Each run emits a unique `request_id`. Look up the full audit entry at `https://jwtshield.com/runs/<id>`.
- **OpenAPI-first.** Public spec at [jwtshield.com/jwtshield.openapi.json](https://jwtshield.com/jwtshield.openapi.json).

## Examples

### Block on PR if any high-severity issue lands

```yaml
on: [pull_request]
jobs:
  auth:
    runs-on: ubuntu-latest
    steps:
      - uses: redbullhorns/jwtshield-ci@v1
        with:
          issuer: https://login.example.com
          audience: api://backend
          fail-on-severity: high
          api-key: ${{ secrets.JWTSHIELD_API_KEY }}
```

### Validate a synthetic token from your test fixtures

```yaml
on: [pull_request]
jobs:
  auth-regression:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: token
        run: echo "value=$(./scripts/mint-test-token.sh)" >> "$GITHUB_OUTPUT"
      - uses: redbullhorns/jwtshield-ci@v1
        with:
          issuer: https://login.example.com
          audience: api://backend
          allowed-algs: RS256,ES256
          fail-on-severity: high
          token: ${{ steps.token.outputs.value }}
          api-key: ${{ secrets.JWTSHIELD_API_KEY }}
```

### Nightly OIDC config drift watch (warn-only)

```yaml
on:
  schedule:
    - cron: '0 6 * * *'  # 06:00 UTC daily
jobs:
  oidc-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: redbullhorns/jwtshield-ci@v1
        with:
          issuer: https://login.example.com
          audience: api://backend
          fail-on-severity: critical
          fail-mode: soft
          api-key: ${{ secrets.JWTSHIELD_API_KEY }}
```

### React to status from a downstream step

```yaml
- id: jwt
  uses: redbullhorns/jwtshield-ci@v1
  with:
    issuer: https://login.example.com
    audience: api://backend
    api-key: ${{ secrets.JWTSHIELD_API_KEY }}

- if: steps.jwt.outputs.status == 'fail'
  run: echo "::warning::jwtshield found ${{ steps.jwt.outputs.findings-count }} issues. Evidence: ${{ steps.jwt.outputs.evidence-url }}"
```

## Pricing

| Tier | Price | Verifies / month | Issuers |
|---|---|---|---|
| Starter | $0 | 200 | 1 |
| Developer | $49 | 5,000 | 5 |
| Startup | $99 | 10,000 | 10 |
| **Team (recommended)** | **$199** | **50,000** | **25** |
| Enterprise | custom | unlimited | unlimited |

[Compare tiers and start free →](https://jwtshield.com/pricing)

## Versioning

We follow semver. Pin to:
- `@v1` — floating tag, gets non-breaking patches automatically.
- `@v1.0.0` — exact pin, no automatic updates.

## Links

- [jwtshield.com](https://jwtshield.com) — homepage
- [jwtshield.com/docs](https://jwtshield.com/docs) — API reference
- [jwtshield.com/blog/3-jwt-bugs-that-ship-to-prod-silently](https://jwtshield.com/blog/3-jwt-bugs-that-ship-to-prod-silently) — incident classes deep-dive
- [jwtshield.com/security](https://jwtshield.com/security) — trust posture + audit
- [jwtshield.com/runs/&lt;id&gt;](https://jwtshield.com/runs/) — audit trail lookup
- [OpenAPI spec](https://jwtshield.com/jwtshield.openapi.json)

## License

MIT — see `LICENSE`.

Built by [Blue Hills](https://github.com/redbullhorns). Issues and PRs welcome.
