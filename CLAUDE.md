# omnicore-example-users

Sandbox + reference consumer of the [OmniCore](../omnicore/CLAUDE.md) framework. Two purposes: a **test bench** to exercise framework features and surface gaps, and a **canonical example** of assembling a microservice with OmniCore. It is a sandbox — not production; keep it simple.

Implements a users CRUD with addresses as a child aggregate (POST, PUT strict, PATCH partial, PATCH `/:id/archive` + `/unarchive` aggregate-aware, DELETE hard, GET by id, GET by params), plus a second role — **Employee** (`/employees/*`, 100% canonical, no by-id route) — over the SAME shared Person identity, exercising the SharedBase paths one role cannot: base reuse/refcount across roles, two role-owned child collections (`Dependent` + `JobHistory`), a role sibling (`employee_bank_accounts`) and a CHILD-level sibling (`dependent_health_plans`). Also a `ShowcaseFeature` of framework-exercise routes (`/whoami`, `/showcase/keycloak/*`, `/showcase/httpclient/*`, `/showcase/cache/*`, `/echo/*`) and a parallel **manual showcase** under `/showcase/users-custom/*` that hand-rolls every layer above `domain/` for the users aggregate.

- **Module path**: `github.com/ClaudioSchirmer/omnicore-example-users`
- **Local path**: `/Volumes/Lynx/Development/omnicore-stack/omnicore-example-users`

## Working rules

Condensed; the full reasoning lives in [`../omnicore/CLAUDE.md`](../omnicore/CLAUDE.md).

1. **Framework changes need explicit maintainer approval.** A finding here → STOP, document it (files+lines), propose (framework fix vs local workaround), wait. No local workaround without approval either — the fix-vs-workaround call is the maintainer's.
2. **The `qa/` suites are an oracle, not editable to pass.** A failing case is a signal — investigate the real cause, report, wait for approval before touching any expectation/fixture. Adding new cases for new behavior is fine and expected.
3. **Unit-test every change.** Wrap up a round with green `go build -tags postgres ./... && go vet -tags postgres ./... && go test -tags postgres ./... -count=1` (this service's dialect is postgres). Then ask via `AskUserQuestion` whether to also run the E2E suites — recommend the relevant subset, always offer "run all".
4. **Verify, never guess** — back every claim about the code with a `Read`/`grep`, including while planning.
5. **English everywhere** except the seven translation catalogs in `application/translations/` (`ptbr`/`eng`/`esp`/`fra`/`deu`/`ita`/`nld`).
6. **The AI never writes git history.** Get onto a coherent branch at task start (`feature|fix|docs|refactor/<slug>` via `git checkout -b` off `main`, or `git branch -m` to rename an in-flight branch); apply edits; deliver one English commit-message suggestion as chat text. No commit/push/tag/PR/release.
7. **This file is current state, not history** — no "Phase N", no changelog/dated entries, no references to removed APIs.

## Layout

Standard DDD layers consuming the framework:

- `domain/` — `User` + `Employee` (`AggregateRoot`s over the same Person identity), `Address` (base-child `AggregateValueObject`, shared across roles), `Dependent` (role child carrying the health-plan sibling facet) + `JobHistory` (role child), custom notifications, the manual-showcase repository port. Pure, zero IO.
- `application/` — `commands/` (+ co-located Results + manual `commands/handlers/`), `queries/` (+ manual `queries/handlers/`), `dtos/`, `translations/` (7 catalogs).
- `infra/` — `schema.go` (the explicit `TableSchema` Go↔column map, threaded into both repos + the view), repositories, `views.go`, `external/` (outbound HTTP adapters wrapping `omnicore/infra/httpclient`). Go only.
- `web/` — Fiber routes (`MountXxx` per concern), `requests/` (+ co-located Responses), `responses/`. Owner of wire tags.
- `bootstrap/` — `package main`: `main.go` (~10 lines), `wire.go`, one `*_feature.go` per feature.
- `migrations/{postgres,mysql}/` — domain DDL split by dialect; service migrations start at `0002` (the framework injects `0001`).
- `devops/` — local bench (`docker-compose.yml`, `debezium/`, `keycloak/`, `elk/`); replaced by real infra in production.
- `qa/` — end-to-end bash suites (see below).
- `microservice.*.yaml` — one file per profile (`dev` + `prd*` auth variants), selected by `APP_PROFILE`.

Import alias convention in files needing both `domain` packages: `domain` = framework, `appdomain` = this service, `fwinfra` = framework infra.

For any framework concept (BaseEntity, Rules DSL, Pipeline, Auto handlers, BaseRepository/ScopedRepository, AggregateLoader, TableSchema, ViewReader, auth/authz, httpclient, cache, integration events, tracing, bootstrap, OpenAPI, GraphQL, migrations), see [`../omnicore/CLAUDE.md`](../omnicore/CLAUDE.md) and its Documentation Map into the HTML manual at `../omnicore/docs/`.

## Example-specific notes

- **Backend-agnostic.** Repos/service/tests take the neutral `core.RelationalEngine` (`Deps.DB`); the SQL backend is chosen by `relational.dialect` in YAML. Only the YAML, `devops/`, and `qa/*.sh` name a concrete backend.
- **Manual showcase** (`/showcase/users-custom/*`) persists the SAME `users`/`addresses` tables as `/users/*`; it exists to make the wrapper internals visible. Identifier is the user's **email** (`path:"email"`), treated as immutable on that surface. Projection still reuses framework infrastructure (`AutoFromDoc`/`RespondPaged`) — "manual" means the orchestration steps, not re-implementing primitives.
- **Authorization** — all three framework layers are exercised: Layer 1 (`fwopenapi.RequirePermission` on routes), Layer 2 (`BuildRules` owner-check via `actionName == "GetArchivable"`, fields fed by the Command mapper from `ctx.Identity()`), Layer 3 (tenant) wired but not exercised (User has no `tenant_id`).
- **Nullables** — empty JSON input → nil → NULL (`User.Phone`, `Address.Label`/`Complement`); no `db:` tags, the Go↔column map lives in `infra/schema.go`.

## How to run

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh            # idempotent
APP_PROFILE=dev go run -tags postgres ./bootstrap  # framework applies migrations at boot
```

A relational engine build tag is **mandatory**: `-tags postgres`, `-tags mysql`, or both (`-tags 'postgres mysql'` → dialect chosen at boot from `relational.dialect`). Read side is eventually consistent (Debezium → Kafka → SyncEngine → Mongo, ~100-300ms after a write).

**Local ports** (non-default, set in `devops/docker-compose.yml`): app `8080`, relational `5433`, mongo `27018`, kafka `9094`, debezium `8083`, keycloak `8088`, jaeger `16686`. Dev relational creds: `omnicore`/`omnicore`, db `users_db`. The jaeger + ELK containers are optional observability; nothing in the data plane depends on them.

## QA suites (`qa/`)

Ten end-to-end bash+curl scripts, plus the orchestrator **`qa/run.sh`** — the one-command matrix: `./qa/run.sh` runs every suite against BOTH backends in the right order (it builds the dual-engine binary once, boots/stops the server for the "running already" suites, frees :8080 for the self-managed ones, registers each backend's connector and waits for it to be RUNNING) and reports per suite × backend: console lines plus an incrementally written markdown report at the **stack root** (`../qa-report.md`), with a final verdict (exit 0 only when every scheduled run completed green — an aborted backend leaves an ABORT row and runs that never started also turn the verdict red). `./qa/run.sh postgres|mysql` limits the backend; `SUITES="e2e employee" ./qa/run.sh` limits the suites. All need `docker compose up` + `register-connector.sh`; some also need Keycloak ready. **Dialect-driven**: every script sources `qa/_backend.sh` and runs against either backend via `BACKEND=postgres|mysql` (default postgres). The QA build is the dual-engine binary; all nine are green on both backends. **Running "the QA suite" means running against BOTH backends — postgres first, then mysql — never just one. The two engines diverge on dialect specifics (placeholder `$n` vs `?`, arg order, UUID codec), so a green postgres run does not imply mysql; validate both.** For mysql, register the mysql connector (`./devops/debezium/register-connector.sh mysql`) then re-run each script with `BACKEND=mysql`. Per rule #2, expectations are an oracle — don't edit them to mask a regression.

| Script | Covers | Server | Notes |
|---|---|---|---|
| `e2e.sh` | every write/read route + every custom notification + CSV/XLSX export | running already | `APP_PROFILE=dev` |
| `employee.sh` | the Employee role: SharedBase reuse/refcount across roles, vetoable purge (+ its audit/outbox), role children, role sibling + child-level (A2b) sibling, archive cascade + base convergence, exports, GraphQL | running already | `APP_PROFILE=dev` |
| `auth.sh` | JWT middleware across 4 validator modes (`prd`/`prd-pem`/`prd-external`/`prd-external-cached`) | self-managed | needs Keycloak; ~5 min (cache-TTL wait) |
| `audit.sh` | audit pipeline end-to-end (slog echo + in-TX row) per write verb | self-managed | `APP_PROFILE=prd`; ~10s |
| `httpclient.sh` | outbound HTTP showcase (keycloak + echo: cache, oauth2, streaming, multipart, SSE, HMAC, inline auth) | running already | ~3s |
| `cache.sh` | cache subsystem (private + shared, TTL, failOpen, cross-process) | self-managed | needs redis container; ~30s |
| `openapi.sh` | OpenAPI doc + Swagger UI surface | running already | needs `jq`; ~1s |
| `authz.sh` | authorization Layer 1 + Layer 2 + public bypass + GraphQL gate | self-managed | `APP_PROFILE=prd-authz`; needs Keycloak; ~30s |
| `schema_evolution.sh` | Mongo wipe-and-recover via registry + advisory lock | self-managed | `APP_PROFILE=dev`; ~30s |
| `graphql.sh` | GraphQL endpoint (introspection, Relay reads, mutations, validation errors, count-only, pagination) | running already | needs `jq` + CDC; ~10s |
| `config_validation.sh` | boot-time config rejection (missing mandatory field, auth.mode=disabled outside dev, cache.shared.store=memory) | self-managed | ~5s; no infra beyond the binary |
| `migrations.sh` | relational migration control plane — autoRun modes (true/check/false) + dirty→Force recovery, via a temp `MIGRATIONS_DIR` + synthetic 0003 probe | self-managed | `APP_PROFILE=dev`; ~30s |
| `tracing.sh` | distributed tracing — Jaeger service + span tree (server + pgx/mongo children) + correlationID==trace_id (audit slog traceId resolves in Jaeger) | self-managed | brings up the jaeger container; ~30s |
| `status_mapping.sh` | HTTP status mappings the canonical example skips — 413 (body over BodyLimit), 500 (recovered panic), 503 (ServiceUnavailableNotification) via /qa/showcase/* | self-managed | qa binary; ~15s |
| `lifecycle_hooks.sh` | in-TX write hooks (AfterBegin + BeforeCommit) on the Auto AND manual paths + forced rollback — asserted against the gadget_journal (no CDC) | self-managed | qa binary; ~15s |
| `filter_operators.sh` | the full 16-operator query-filter vocabulary on a live view + the exact-allowlist guard (undeclared operator → 400) | self-managed | qa binary + CDC; ~30s |
| `view_options.sh` | read-side view options — MaxLimit(5) ?limit reject, RawDoc projector passthrough, DeleteOnArchive (archived rows drop from `gadgets_hot`, kept-hidden in `gadgets`) | self-managed | qa binary + CDC; ~30s |
| `httpclient_middleware.sh` | outbound httpclient middleware — retry backoff, circuit breaker (ErrCircuitOpen), idempotency key (source ctx), XML request codec, bearer-static provider + header cascade + per-call WithExtraHeader — via a qa self-call showcase (/qa/echo/* ↔ /qa/showcase/httpclient/*) | self-managed | qa binary; ~15s |
| `upstream_composition.sh` | service-to-service upstream composition — filtered local projection + onUpstreamDelete cascade + failure registry/admin drain | self-managed | qa binary + `microservice.qa.yaml`; needs CDC; ~40s |
| `integration_events.sh` | integration events — in-TX dispatch, receiver→sink, dedup, idempotency, admin drain | self-managed | qa binary + `microservice.qa.yaml` + a qa Debezium connector on `integration_events` (pgoutput / binlog variant per engine, routing to a backend-specific `qa.integration.events[.mysql]` topic); ~40s |

"Self-managed" scripts build + start + stop the server themselves; the "running already" scripts (`e2e`, `employee`, `httpclient`, `openapi`, `graphql`) need the service started in another terminal first — start the dual-engine binary (`go build -tags 'postgres mysql' -o /tmp/srv ./bootstrap`) with the target backend's env sourced from `qa/_backend.sh` (`export BACKEND=mysql; source qa/_backend.sh; APP_PROFILE=dev /tmp/srv`) so the boot dialect matches the suite's `BACKEND`.

**The Gadget-mirror suites** (`lifecycle_hooks`, `filter_operators`, `view_options`, `status_mapping`, `httpclient_middleware`, `upstream_composition`, `integration_events`) build their OWN `-tags '<engine> qa'` binary and boot `microservice.qa.yaml` (= dev.yaml + the qa integration/upstream wiring) via `OMNICORE_CONFIG_PATH`. They exercise the **qa-only `Gadget` mirror aggregate** (`//go:build qa`, under the `*/qafixtures/` subpackages) — the framework features the canonical User/Employee example does not: lifecycle hooks, the full filter-operator vocabulary, DeleteOnArchive/MaxLimit/RawDoc view options, the 413/500/503 status mappings, the advanced httpclient middleware, and the integration-events / upstream-composition subsystems. All of it is invisible to the canonical binary (`go build ./bootstrap` never compiles it), so a reader of the reference service is never confused by QA scaffolding.
