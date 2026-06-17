## omnicore-example-users

> **CRITICAL RULE — DO NOT CHANGE THE FRAMEWORK WITHOUT APPROVAL**
>
> This service is the primary source of findings that become improvements in the framework — exactly for that reason, the rule is strict: **any and every change to `../omnicore/` must be explicitly approved by the maintainer before being applied.**
>
> When a finding comes up while working on this example:
> 1. **STOP.** Do not apply anything — neither to the framework, nor as a local workaround.
> 2. Document the finding (what is missing, what is buggy, what could be more generic) with the relevant files + lines.
> 3. Present it to the maintainer with: (a) description of the bug/gap, (b) proposed fix in the framework, (c) local workaround alternative if applicable.
> 4. **Wait for explicit approval BEFORE any change — including a local workaround in the consumer service.** The choice between "fix the framework" and "work around locally" belongs to the maintainer, never to the AI. "A workaround is faster" is not a justification for acting without asking.
> 5. After an explicit decision, execute the chosen option.
>
> Flow details in [`../omnicore/CLAUDE.md`](../omnicore/CLAUDE.md).

> **CRITICAL RULE — THE QA SUITE (`qa/`) IS NOT REWRITTEN WITHOUT APPROVAL**
>
> The `qa/e2e.sh` suite is the oracle of expected endpoint behavior — including status codes, response shape, and notification coverage. **A test failure is a signal, not a problem to silence.**
>
> When a case of the suite breaks:
> 1. **STOP.** Do not edit the assert, expected status, body fixture, or remove the case.
> 2. Investigate the real cause (regression in the service? regression in the framework? timing/CDC? was the test expectation wrong?).
> 3. Report the finding to the maintainer with diagnosis — same flow as the rule above.
> 4. **Wait for explicit approval BEFORE touching `qa/`.** Changing an expectation from 404 to 200 just because "it now returns 200" masks regressions. Reducing coverage without asking loses historical signal.
> 5. New cases, expectation adjustments, helpers, suite refactors — everything goes through explicit approval first.
>
> A "workaround in the test" (adjust expected to match current, comment out a case, skip) is as serious or more so than a workaround in the consumer code: it creates a false sense of health. The suite is the ruler; you don't rewrite the ruler to accommodate what is being measured.

> **CRITICAL RULE — UNIT TESTS ACCOMPANY EVERY CHANGE**
>
> Strict stack ruler:
>
> 1. **Every code change comes with a unit test covering the new/changed behavior.** A green build/vet is not proof of behavior. A hard-to-test case (complex mock, depends on I/O) → report to the maintainer before proceeding; do not skip the test.
> 2. **When wrapping up a round of changes**, run the unit suite of the affected module(s):
>    ```bash
>    cd omnicore-example-users && go build ./... && go vet ./... && go test ./... -count=1
>    # And if the change touched the framework:
>    cd ../omnicore && go build ./... && go vet ./... && go test ./... -count=1
>    ```
>    A green suite is a precondition of "done".
> 3. **After the unit suite passes, ask the maintainer whether to also run the E2E QA suites** in `qa/`. The folder holds eight scripts — `qa/e2e.sh` (endpoint + notification coverage, auth disabled), `qa/auth.sh` (JWT middleware across the four validator modes, ~5 min), `qa/audit.sh` (audit pipeline end-to-end — slog echo + in-TX `audit_events` row), `qa/httpclient.sh` (outbound HTTP showcase coverage with the in-process memory cache, ~3s), `qa/httpclient-redis.sh` (outbound HTTP cache backend swapped to Redis via `microservice.dev-redis-cache.yaml` — keys/TTL/JSON shape inspected via `docker compose exec redis redis-cli`, plus cross-process persistence and failOpen, ~30s; needs the `redis` container up), `qa/openapi.sh` (OpenAPI document + Swagger UI surface, ~1s), `qa/authz.sh` (declarative permission layer end-to-end under `prd-authz`, ~30s), `qa/schema_evolution.sh` (Mongo wipe-and-recover via the registry + advisory-lock primitives under `dev`, ~30s). The question MUST go through `AskUserQuestion`: based on the changes just made, recommend the relevant subset (most specific first, marked "(Recommended)") and **always include an option to run all eight**. E.g. after touching the auth middleware: "Run auth.sh (Recommended)" / "Run auth.sh + audit.sh" / "Run all eight" / "Skip for now". The suites are opt-in because they need `docker compose -f devops/docker-compose.yml up -d` + `./devops/debezium/register-connector.sh` (auth/audit/httpclient/httpclient-redis/authz also need Keycloak ready; httpclient-redis additionally needs the `redis` container up) — wait for the maintainer's reply before executing.

> **CRITICAL RULE — DO NOT GUESS, VERIFY BEFORE ASSERTING OR PLANNING**
>
> Every claim about the code (return types, function signatures, layer behavior, what a handler does, what a wrapper emits, whether a function exists, what an env var defaults to, where a setting is read) MUST be backed by reading the actual source — never plausible-sounding inference from names, surrounding context, or pattern-matching against similar codebases. The truth is one `Read`/`grep` away; skipping that step to sound fast is failure.
>
> **The same applies to planning.** A proposed change that assumes a function works a certain way without checking is the same failure mode in a different dress — guessing dressed up as design. Verify the assumption before writing the plan, not after the maintainer points out the mistake. A plan built on a guessed contract has no value; redo the verification step, then redo the plan.
>
> When uncertain: either run the lookup before answering, or say explicitly "I'm guessing — let me verify" and then verify. **Never present a guess as a fact.** A wrong answer is worse than "I need to check first" because it gets quoted back, propagated into other files, and only gets corrected when it visibly breaks something — and by then it has cost trust + rework.
>
> The source code is the ground truth. The maintainer's words are the ground truth for intent. The AI's pattern-matched inference is not.

> **CRITICAL RULE — ENGLISH IS THE LANGUAGE OF THIS EXAMPLE**
>
> All code, comments, documentation (including this `CLAUDE.md`), identifiers, file names, test fixtures (QA scripts included), log messages, and error strings in this service are written in **English** — no exceptions. As the canonical example of the framework, it follows the same rule the framework imposes on itself.
>
> **The only exception** is translation strings inside `application/translations/` — this service's i18n catalog. By design it ships with **seven languages**: PT-BR (`ptbr.go`), English (`eng.go`), Spanish (`esp.go`), French (`fra.go`), German (`deu.go`), Italian (`ita.go`), and Dutch (`nld.go`), mirroring the framework's own catalog in `omnicore/application/translation/`. Those seven modules are the *only* place in this service where non-English text is allowed; the surrounding Go code (struct names, function names, identifiers, comments) stays English even inside the translations package.
>
> Maintainer ↔ Claude conversations can happen in any language — the artifacts on disk remain English (except the four translation modules above). **Other future microservices** (siblings of this example) may pick different language preferences per maintainer decision; this canonical example stays English-only.

> **CRITICAL RULE — AI DOES NOT COMMIT, PUSH, OR OPEN PRs**
>
> The maintainer keeps absolute control of the git tree and the GitHub remote. **The AI is strictly forbidden from running any command that records a commit or writes to the remote:**
> - `git commit` in any form (including `--amend`, with or without `-m`).
> - `git push` in any form (fast-forward, force, force-with-lease, tags, releases).
> - `git tag` (local creation or pushed).
> - `gh pr create` / `gh release create` / any `gh api` invocation that modifies state.
> - Any other command that records a commit or modifies remote git state.
>
> Read-only git inspection (`git status`, `git log`, `git diff`, `git branch --list`) and file edits via the `Edit` / `Read` / `Write` tools remain allowed.
>
> **The closed loop the AI follows on every task:**
>
> 1. **At task start, create a feature branch with a coherent descriptor.** Prefix by intent (`feature/<slug>` for new behavior, `fix/<slug>` for bug fixes, `docs/<slug>` for doc-only edits, `refactor/<slug>` for internal cleanups). The slug is lowercase-kebab-case and names the *outcome*, not the file edited: `feature/keycloak-showcase-redact`, not `feature/edit-handler`. `git checkout -b <branch>` is the only git-write the AI runs — it is structural setup (local, reversible) so the maintainer's main tree stays clean from in-flight work.
>
> 2. **Apply the file changes for the task on that branch** via the `Edit` / `Read` / `Write` tools.
>
> 3. **At task end, deliver one commit-message suggestion in English** as plain chat text for the maintainer to copy/use:
>    - Title in the imperative mood (~72 chars max).
>    - Optional body in short paragraphs explaining the *why* of the change.
>    - No `Co-Authored-By` trailer — the suggestion is clean for the maintainer to use verbatim.
>
> The maintainer is the sole actor who runs `git commit`, `git push`, creates tags/releases, opens PRs, and merges. The AI's job ends when the file changes are applied to the feature branch and the commit-message suggestion is delivered in chat.

> **CRITICAL RULE — THIS DOCUMENT DESCRIBES THE CURRENT STATE, NOT HISTORY**
>
> `CLAUDE.md` is a **spec of what IS**, not a changelog of what changed. When a change ships, edit the relevant sections to describe the new behavior directly — do not append "Phase N" / "Sandbox findings" entries, do not preserve old wording with "(was X, now Y)" framing, do not annotate features with "(Phase 21)" tags.
>
> Forbidden:
> - "Phase N" labels in section headings, inline parentheticals, or code comments
> - A "Sandbox findings" / "Project history" / "Changelog" / dated-entry section
> - "X used to be Y, now is Z", "after the reorg", "previously declared via M" framing — describe the current behavior directly
> - References to APIs, types, paths, or fields that no longer exist in the code (`cmd/server/`, `app/`, `AggregateMapping`, `ChildMapping`, `HardDelete`, etc. — if it's gone from the repo, it's gone from here)
>
> Project history lives in git (`git log`, commit messages, PR descriptions). The maintainer remembers his own decisions. When the spec contradicts the code, the spec is wrong — fix it in the same round as the code change, not in a later cleanup.

---

Example/sandbox microservice that consumes the [OmniCore](../omnicore/CLAUDE.md) framework. Two purposes:

1. **Test bench** — exercise framework functionality and surface gaps or points that could be more generic.
2. **Reference example** — canonical reference for how to assemble a microservice with OmniCore.

Implements a users CRUD with addresses as a child aggregate. Endpoints: POST, PUT (full replace, strict body), PATCH `/:id` (partial), PATCH `/:id/archive` + `/:id/unarchive` (aggregate-aware), DELETE (hard), GET by ID, GET by params. Together the endpoints exercise the framework's 5 write verbs (Insert/Update/Archive/Unarchive/Delete) — PUT vs PATCH distinction lives in the handler name (`UpdateCommandHandler` strict via marker `FullBody` vs `PartialUpdateCommandHandler` lenient).

A separate `ShowcaseFeature` registers **framework-exercise routes** under their own context:
- `GET /whoami` — `AppContext.Identity()` demo.
- `/showcase/keycloak/*` — outbound auth providers against the Keycloak fixture (anonymous + cache, `oauth2-client-credentials`, `credentials-exchange`).
- `/showcase/httpclient/*` — outbound streaming surfaces (download, upload, multipart, SSE), HMAC signing, `CallConfig` per-call overrides, `InlineAuth` runtime credentials. Driven by the in-process `/echo/*` upstream that the same feature mounts.
- `/echo/*` — minimal producer for `/showcase/httpclient/*` (records bytes, parses multipart, streams SSE events, captures signing headers). Kept at the root rather than under `/showcase` because it is the upstream of the demos, not a demo itself.

These routes are intentionally **outside** `/users/*` so the canonical "one aggregate, one feature, one Mount" pattern stays visible in `UsersFeature` / `MountUsers`. Their consumer side lives in `infra/external/keycloak_service.go` and `infra/external/echo_service.go` — handlers depend on a vendor service struct; only those structs import `omnicore/infra/httpclient`.

- **Module path**: `github.com/ClaudioSchirmer/omnicore-example-users`
- **Local path**: `/Volumes/Lynx/Development/omnicore-stack/omnicore-example-users`

---

## Workspace setup

This service consumes the published `omnicore` module from `proxy.golang.org` — `go.mod` declares `require github.com/ClaudioSchirmer/omnicore v<x.y.z>` with no `replace` directive. A `go build ./...` from a clean clone resolves the framework via the Go proxy without any extra setup.

For day-to-day development where you want cross-module navigation in the IDE and instant builds against an in-tree framework checkout, the recommended layout is a local workspace folder pairing both clones as siblings:

```
~/Development/omnicore-stack/    ← pasta local, sem .git próprio
├── go.work                      ← lists both modules; gitignored
├── omnicore/                    ← git clone of github.com/ClaudioSchirmer/omnicore
└── omnicore-example-users/      ← git clone of this repo
```

`go.work` is the Go ≥1.18 canonical multi-module workspace mechanism. It overlays the published module with the local checkout so jump-to-def + `go build ./...` work across both without `replace`. The file is gitignored — every developer has their own.

For framework concepts (`BaseEntity`, `Rules DSL`, `Pipeline`, `Orchestrator`, `Auto Command Handlers`, `BaseRepository`, `AggregateLoader`, `NotificationSemantic`, `bootstrap.Run`, Migration manager, ViewReader, etc.), see the framework's [`CLAUDE.md`](https://github.com/ClaudioSchirmer/omnicore/blob/main/CLAUDE.md) (maintainer-side) or [`DOCS.html`](https://github.com/ClaudioSchirmer/omnicore/blob/main/DOCS.html) (consumer-side). This document describes only what is specific to this service.

---

## Structure

```
omnicore-example-users/
├── domain/                        # Pure DDD, zero IO
│   ├── notifications.go           # 9 custom notifications (Invalid*, *AlreadyExists with Semantic Conflict, NameMaxLengthExceededNotification with tvar:"maxLength"); User + Address fields carry `label:"<catalogKey>"` tags consumed by the framework's field-label resolver
│   ├── address.go                 # Address (AggregateValueObject)
│   └── user.go                    # User (AggregateRoot + AggregateRootProvider)
├── infra/                         # Adapters, imports omnicore/infra (implementation of domain ports — Go only)
│   ├── user_repository.go         # BaseRepository[*User] + AggregateLoader[*User]
│   ├── user_custom_repository.go  # Manual UserCustomRepository for /showcase/users-custom/* — FindByEmail + write delegation
│   ├── views.go                   # UserView ViewDefinition (called ONCE via UsersFeature)
│   └── external/                  # Outbound HTTP adapters — wrap omnicore/infra/httpclient
│       └── keycloak_service.go    # KeycloakService: GetRealmInfo, FetchUser, WhoamiTenant + vendor-neutral DTOs
├── migrations/                    # Schema contract of the domain (versioned with domain/*.go)
│   ├── 0002_init.up.sql           # users + addresses (version 1 is the framework's embedded outbox)
│   └── 0002_init.down.sql         # DROP TABLE addresses + users
├── devops/                        # Scaffolding the service doesn't know about (framework pipeline + local bench)
│   ├── docker-compose.yml         # Postgres + Mongo + Kafka (KRaft) + Debezium + Keycloak
│   ├── debezium/                  # Framework CDC pipeline scaffolding — outbox → Kafka Connect
│   │   ├── users-outbox-connector.json  # Connector config (parameterized: name, DSN, topic prefix)
│   │   └── register-connector.sh         # Idempotent registration script
│   └── keycloak/                  # Test IdP scaffolding — only used by qa/auth.sh + qa/audit.sh + qa/authz.sh
│       ├── realm-export.json            # Realm omnicore-test + pinned RS256 keys + test users + clients
│       ├── wait-ready.sh                # Polls /realms/omnicore-test until ready
│       ├── mint-token.sh                # Mints access tokens (alice/bob/client/wrong-aud, --raw, --refresh)
│       └── revoke-session.sh            # Revokes a token via RFC 7009 /revoke (introspection then returns active=false)
├── application/
│   ├── commands/                  # Commands + co-located Results (Go-pure, no JSON tags)
│   │   ├── insert_user.go                  # InsertUserCommand + ToEntity + FromEntity; InsertUserResult struct (pure data)
│   │   ├── update_user.go                  # UpdateUserCommand + ApplyTo + FromEntity; UpdateUserResult struct (pure data)
│   │   ├── patch_user.go                   # PatchUserCommand + ApplyPartiallyTo + FromEntity; PatchUserResult struct (pure data)
│   │   ├── archive_user.go                 # ArchiveUserCommand (canonical, ID only — endpoint uses fwresults.None)
│   │   ├── unarchive_user.go               # UnarchiveUserCommand (canonical, ID only — endpoint uses fwresults.None)
│   │   ├── delete_user.go                  # DeleteUserCommand (canonical, ID only — endpoint uses fwresults.None)
│   │   ├── insert_user_custom_command.go   # InsertUserCustomCommand + ToEntity (manual POST)
│   │   ├── update_user_custom_command.go   # UpdateUserCustomCommand + ApplyTo (manual PUT, EmailKey, no Email field)
│   │   ├── patch_user_custom_command.go    # PatchUserCustomCommand + ApplyPartiallyTo (manual PATCH, EmailKey)
│   │   ├── archive_user_custom_command.go  # ArchiveUserCustomCommand (manual, EmailKey only)
│   │   ├── unarchive_user_custom_command.go# UnarchiveUserCustomCommand (manual, EmailKey only)
│   │   ├── delete_user_custom_command.go   # DeleteUserCustomCommand (manual, EmailKey only)
│   │   └── user_custom_result.go           # UserCustomResult + AddressCustomResult (pure data) + userCustomResultFromUser helper consumed by each Cmd.FromEntity on the manual showcase
│   ├── handlers/                  # Manual application handlers for /showcase/users-custom/*
│   │   ├── ports_custom.go                        # UserCustomRepository interface (Repository[*User] + FindByEmail/FindArchivedByEmail)
│   │   ├── insert_user_custom_handler.go          # ToEntity → GetInsertable → Orchestrator.Insert → SetID → cmd.FromEntity(ctx, user); returns UserCustomResult
│   │   ├── update_user_custom_handler.go          # FindByEmail → GetUpdatable → Orchestrator.Update → cmd.FromEntity(ctx, user); returns UserCustomResult
│   │   ├── patch_user_custom_handler.go           # FindByEmail → GetPartialUpdatable → Orchestrator.Update → cmd.FromEntity(ctx, user); returns UserCustomResult
│   │   ├── archive_user_custom_handler.go         # FindByEmail → GetArchivable → Orchestrator.Archive; returns fwresults.None
│   │   ├── unarchive_user_custom_handler.go       # FindArchivedByEmail → GetUnarchivable → Orchestrator.Unarchive; returns fwresults.None
│   │   ├── delete_user_custom_handler.go          # FindByEmail → GetDeletable → Orchestrator.Delete; returns struct{}
│   │   ├── find_user_by_email_custom_handler.go   # ReadPage with Filter[email]=<value> Limit=1; carries access-control filter seam
│   │   └── find_users_custom_handler.go           # ReadPage with parsed criteria; same access-control seam
│   ├── queries/                   # Query types
│   │   ├── find_user_by_params_query.go    # FindUserByParamsQuery + ToCriteria(ctx) (canonical)
│   │   ├── find_user_by_id_query.go        # FindUserByIDQuery + ToCriteria(ctx) returning ReadCriteria{IncludeArchived: q.Archived} (canonical)
│   │   ├── find_user_by_email_custom_query.go     # FindUserByEmailQuery + ToCriteria(ctx) (manual showcase)
│   │   └── find_users_custom_query.go      # FindUsersCustomQuery embeds ReadCriteria (manual showcase)
│   ├── dtos/                      # DTOs consumed by Commands (no JSON tags)
│   │   ├── address_input.go       # AddressInput — canonical Insert/Update commands
│   │   └── address_input_custom.go # AddressInputCustom — manual showcase Insert/Update commands
│   └── translations/              # Custom notifications PTBR + ENG + ESP + FRA + DEU + ITA + NLD
│       ├── ptbr.go
│       └── eng.go
├── web/
│   ├── user_routes.go             # MountUsers — /users/* CRUD + queries (Spec siblings + openapi.Mount)
│   ├── user_custom_routes.go      # MountUsersCustom — /showcase/users-custom/* manual chain via openapi.Mount with hand-rolled RouteSpec
│   ├── whoami_routes.go           # MountWhoami — GET /whoami via openapi.MountRaw + declared WhoamiResponse
│   ├── keycloak_routes.go         # Keycloak handlers consumed by MountShowcase
│   ├── showcase_routes.go         # MountShowcase — /showcase/keycloak/* + /showcase/httpclient/* via openapi.MountRaw (Public: true)
│   ├── echo_routes.go             # MountEcho — /echo/* in-process upstream via openapi.MountRaw (Hidden: true — excluded from spec)
│   ├── respond.go                 # respondWithError shared helper
│   ├── requests/                  # Request DTOs + co-located Response DTOs (JSON wire format)
│   │   ├── address_request.go              # AddressRequest + ToAddressInput() (canonical)
│   │   ├── address_custom_request.go       # AddressCustomRequest + ToAddressInput() (manual showcase)
│   │   ├── insert_user_request.go          # InsertUserRequest + ToCommand() + InsertUserResponse + FromResult (canonical POST)
│   │   ├── update_user_request.go          # UpdateUserRequest + ToCommand() + UpdateUserResponse + FromResult (canonical PUT)
│   │   ├── patch_user_request.go           # PatchUserRequest + ToCommand() + PatchUserResponse + FromResult (canonical PATCH)
│   │   ├── insert_user_custom_request.go   # InsertUserCustomRequest + ToCommand() (manual POST)
│   │   ├── update_user_custom_request.go   # UpdateUserCustomRequest + ToCommand() (manual PUT, no Email)
│   │   ├── patch_user_custom_request.go    # PatchUserCustomRequest + ToCommand() (manual PATCH, no Email)
│   │   ├── user_custom_key_request.go      # UserCustomKeyRequest (Email path:"email") — shared by Archive/Unarchive/Delete bodyless verbs
│   │   ├── find_users_by_params_request.go    # FindUsersByParamsRequest + ToQuery(criteria) + FindUsersByParamsResponse (json:+view: tags, projected via fwresponses.AutoFromDoc)
│   │   ├── find_user_by_id_request.go         # FindUserByIDRequest + ToQuery() + FindUserByIDResponse (json:+view: tags, projected via fwresponses.AutoFromDoc)
│   │   ├── find_user_by_email_custom_request.go # FindUserByEmailCustomRequest (Email path:"email") + ToQuery(criteria) + FindUserByEmailCustomResponse (reduced; projected via fwresponses.AutoFromDoc at the route)
│   │   └── find_users_custom_request.go       # FindUsersCustomRequest (filter tags + ?fields/?sort/?search/?onlyTotal opt-in) + ToQuery(criteria) + FindUsersCustomResponse (reduced; projected via fwresponses.AutoFromDoc at the route)
│   └── responses/                 # Response DTOs for the manual writes (canonical write Responses are co-located with their Requests; read Responses also co-located per endpoint)
│       └── user_custom_response.go              # UserCustomResponse + AddressCustomResponse + FromResult(commands.UserCustomResult) — shared by Insert/Update/Patch (manual showcase)
├── bootstrap/                     # Composition + entry point (package main)
│   ├── main.go                    # ~10 lines: bootstrap.Run(Wire)
│   ├── wire.go                    # Wire(d Deps) Wiring — translations + features + OpenAPI config (publishes /openapi.json + /docs)
│   ├── users_feature.go           # UsersFeature: repo + view + Mount → web.MountUsers
│   ├── showcase_feature.go        # ShowcaseFeature: kc + echo + custom repo/svc + Mount → MountWhoami/Echo/Showcase/UsersCustom
│   ├── admin_feature.go           # AdminFeature: mount-only — POST /admin/retries/{upstream,integration} behind RequirePermission("admin:retry")
│   └── audit_feature.go           # AuditFeature: mount-only — GET /audit/:aggregateId behind RequirePermission("audit:read")
├── microservice.dev.yaml          # Declarative bootstrap config — APP_PROFILE=dev (auth disabled)
├── microservice.prd.yaml          # Canonical prd — JWT validated locally against Keycloak JWKS
├── microservice.prd-pem.yaml      # Variant — JWT validated against the PEM inlined here (key pinned in realm-export)
├── microservice.prd-external.yaml # Variant — local JWT + RFC 7662 introspection at Keycloak, cache off
├── microservice.prd-external-cached.yaml # Variant — same plus 30s positive-only cache
├── microservice.prd-authz.yaml    # Variant — adds auth.authorization.enabled=true on top of canonical prd
├── go.mod
└── CLAUDE.md                      # this file
```

**DDD layout of the example (layer ruler):**

- `domain/` — pure rules (zero IO)
- `application/` — commands + handlers
- `infra/` — implementation of domain ports (Postgres, views, repos) in Go. **No non-Go artifacts live here** — `infra/` is a DDD layer, not an operational dump.
- `web/` — owner of Fiber routes (`MountXxx` per aggregate)
- `bootstrap/` — composition + entry point (`package main`). Contains `main.go` (≤ 10 lines: `bootstrap.Run(Wire)`), `wire.go` (translations + features), `users_feature.go` (struct `UsersFeature` that bundles repo + view and delegates `Mount` to `web.MountUsers`), `showcase_feature.go` (struct `ShowcaseFeature` that bundles the outbound adapters and delegates to `web.MountWhoami` + `web.MountEcho` + `web.MountShowcase`), `admin_feature.go` (struct `AdminFeature` — mount-only, no domain; registers `POST /admin/retries/upstream` and `POST /admin/retries/integration` behind `RequirePermission("admin:retry")`, under Swagger tag `Admin`), and `audit_feature.go` (struct `AuditFeature` — mount-only, no domain; registers `GET /audit/:aggregateId` behind `RequirePermission("audit:read")`, under Swagger tag `Audit`). Run: `go run ./bootstrap`; build: `go install ./bootstrap` produces the binary `bootstrap` (rename via `-o` if you want a different name). Mirrors the name of the framework's `omnicore/bootstrap` package — same intent (assemble and wire everything up), except in the consumer it is the entry point (`package main`)
- `migrations/` — non-Go but **part of the service's contract**: SQL DDL for the domain tables, versioned alongside `domain/*.go`. Each `.up.sql` requires a matching `.down.sql`. Path declared in `microservice.*.yaml` (`migrations.dir: ./migrations`).
- `devops/` — non-Go scaffolding the service doesn't know about: `docker-compose.yml` for the local bench, `debezium/` (framework outbox→Kafka pipeline boilerplate — parameterized by service name + DSN + topic prefix), `keycloak/` (test IdP only used by `qa/auth.sh` + `qa/audit.sh` + `qa/authz.sh`). In production, `devops/` is replaced by whatever real infrastructure the operator provisions (managed PG/Mongo/Kafka/IdP); the service binary doesn't read anything from this folder.
- `qa/` — end-to-end suites operated by bash + curl + python (`e2e.sh`, `auth.sh`, `audit.sh`, `httpclient.sh`, `openapi.sh`, `authz.sh`).

### Feature struct convention

A `bootstrap/<name>_feature.go` struct holds **infra-level adapters that need configuration or domain wrapping** — and ONLY those. Application-layer handlers (anything under `application/handlers/`) are NEVER cached on the feature struct; they are constructed inline inside the per-request closure of each Fiber handler in `web/`.

| Field on a feature struct? | Examples |
|---|---|
| ✅ Yes | `repo` (`NewUserRepository(d.Postgres)` wraps with NewEntity factory + ConstraintBindings), `svc` (`NewUserService(...)` configures a domain service), `view` (`UserView()` declares the Mongo view shape consumed by Views() AND Mount()), `kc` / `echo` (vendor adapter structs `NewKeycloakService(d.HttpClient)` / `NewEchoService(d.HttpClient)` configure the per-vendor httpclient surface). |
| ❌ No | `*pgxpool.Pool`, `*translation.Translator`, `*pipeline.Pipeline`, `bootstrap.Deps` itself, application handlers (`InsertCommandHandler[*User, ...]`, `FindAuditByAggregateQueryHandler{Pool, Translator}`, etc.). These are read straight from `d` at `Mount` time or built inline inside the route's closure. |

**Decision rule:** if the constructor you would call is `appinfra.NewXxx(...)` (a configured infra adapter) or `appexternal.NewXxx(...)` (a configured vendor surface), it belongs on the feature struct. If the constructor is `&apphandlers.YyyHandler{...}` (an application handler that just wraps Deps fields verbatim), it goes inside the per-request closure. When a feature has nothing in the first category (admin / audit / pure mount-only routes), the struct is empty (`type AuditFeature struct{}`, `NewAuditFeature() *AuditFeature`) and `Mount(app, d)` reads everything off `d` — same shape `AdminFeature` follows.

Mirrors how the framework's Auto Command Handlers are constructed: each Fiber wrapper in `web/user_routes.go` builds the handler struct (e.g. `&handlers.InsertCommandHandler[*User, *InsertUserCommand, commands.InsertUserResult]{Repo: repo}`) at the per-request closure level; only the underlying `repo` is the persistent piece. The manual showcase (`web/user_custom_routes.go::customInsertUser`) follows the same convention with `&apphandlers.InsertUserCustomCommandHandler{Repo: repo, Service: svc}` built inside the closure.

---

## Domain

### User (`domain/user.go`)

`AggregateRoot` with 4 flat fields + a collection of `Address` as `AggregateValueObject`.

Implements two framework interfaces:

| Interface | Methods | Purpose |
|---|---|---|
| `domain.Entity` | `Modes`, `RequiresService` (default false), `BuildRules` | Supported modes + validation |
| `domain.AggregateRootProvider` | `GetAggregateRoot`, `AggregateChildren` | Opt-in for aggregate-aware persistence and aggregate boundary |

**`Modes()`** declares the **6 modes** supported: `Display, Insert, Update, Delete, Archive, Unarchive`. The last two are required because the service exposes `PATCH /:id/archive` and `PATCH /:id/unarchive`.

**`AggregateChildren()`** declares that `Address` belongs to this aggregate — a domain definition. The framework's top-level primitives (`AddAggregateChild`, `ChangeAggregateChild`, `RemoveAggregateChild`, `ReplaceAggregateChildrenOf`) consult this list and reject VOs of undeclared types.

**The `users` table is inferred** via `PluralizeSnake(PascalToSnake("User"))`; columns (`name`, `email`, `phone`) inferred from exported fields; child Address FK inferred as `user_id` via `PascalToSnake("User") + "_id"`. No table/column/FK declarations in the domain.

**Domain methods:** `AddAddress(addr Address, svc Service)`, `ChangeAddress(original, replacement Address)`, `RemoveAddress(addr Address)`, `ReplaceAddresses(addrs []Address)`. Commands call these methods — never `AddAggregateChild` directly. `AddAddress` applies the spanning-children invariant (business-identity duplicate via `Address.sameBusinessIdentity`) before delegating to the type-guarded primitive. Service plumbed as a parameter to enable future external lookups (currently always passed as `nil`).

**`BuildRules` deals only with the root fields.** The framework discovers children via reflection on `AggregateRoot.AllAggregateItems()` and auto-fires `Address.BuildRules` for each active item at the boundary (`GetInsertable/Update/Delete`). Anyone wanting to validate VOs **outside** of `AggregateChildren()` (e.g.: tags in a JSONB column) can still call `u.AddAggregateValueObject("TypeName", item)`; types already present in AggregateRoot are ignored in this path.

**Field validations:** name (required + maximum length of 100), email (regex), phone (10-15 digits, nullable). No country-specific fields in the root — the example is deliberately international. The 100-char cap lives in `domain/user.go` as the package-private constant `nameMaxLength` — a pure domain rule of this aggregate, not a configurable per-tenant value. The application layer never references the constant; the rule fires inside `BuildRules.IfInsertOrUpdate`, comparing `len(u.Name)` directly against `nameMaxLength` and emitting `NameMaxLengthExceededNotification{MaxLength: nameMaxLength}` on overflow. The framework's parameterized-notification mechanism substitutes the emitted value into the translated message via the `tvar:"maxLength"` tag on the notification struct (catalog entries declare `{maxLength}` and the renderer substitutes "100" at the wire boundary). If a future requirement demanded per-tenant variability, the rule would migrate from a constant to a `domain.Service` lookup consulted inside `BuildRules` — same notification type, same wire shape, only the source of the value changes.

**Nullables:** `Phone *string` — column `users.phone` is nullable. Convention of the example: empty input from JSON becomes nil via `commands.NilIfEmpty` at the boundary (Insert/Update/Patch commands). Domain tests `if u.Phone != nil && *u.Phone != ""`. pgx writes NULL when nil; auto-scan reads NULL as nil. No `db:` tags on the struct — the framework's snake_case convention matches directly.

### Address (`domain/address.go`)

`AggregateValueObject` value type (not pointer) — needed so `reflect.DeepEqual` in the type-guarded primitives (`AddAggregateChild`/`ChangeAggregateChild`) compares by field equality.

- **`ID` exposed as a field** — empty for new, populated when loaded from DB by AggregateLoader auto-scan. `GetID()` returns it.
- **No `ToFields()`** — framework extracts columns via reflection on exported fields; `ID` is skipped on write (DB-gen + WHERE); FK `user_id` is injected by infra.
- **`Label *string`, `Complement *string`** — nullable columns. Same convention as `User.Phone`: empty input → nil → NULL in the DB. Auto-scan reads NULL as nil back.
- **Validations by shape, no country branches:** `state` and `zipCode` are validated by generic regexes that accept data from any country (US `"CA"`/`"94103-1234"`, UK `"England"`/`"SW1A 1AA"`, Brazil `"PE"`/`"50000-000"`, Germany `"Bayern"`/`"80331"`). `country` is checked as an ISO 3166-1 alpha-2 shape (2 uppercase letters).
- **`sameBusinessIdentity(other Address) bool`** — Country + ZipCode + Street + Number. Used by `User.AddAddress` to detect spanning-children duplicates. It is not Go equivalence (does not use `reflect.DeepEqual`); it is business equivalence.

### Notifications (`domain/notifications.go`)

| Notification | Fired on | Semantic |
|---|---|---|
| `InvalidEmailNotification`, `InvalidPhoneNotification` | User's `BuildRules` | Validation (422) |
| `InvalidStateNotification`, `InvalidZipCodeNotification`, `InvalidCountryNotification` | `Address.BuildRules` | Validation (422) |
| `EmailAlreadyExistsNotification` | `BaseRepository` via `Constraints` upon detecting a PG unique violation | **Conflict (409)** via `Semantic()` override |
| `DuplicateAddressNotification` | `User.AddAddress` upon detecting `sameBusinessIdentity` with an address already in the aggregate | Validation (422) — request shape carries the duplicate |
| `EmailCannotChangeNotification` | `User.BuildRules.IfUpdate` when `domain.Old(u).Email != u.Email` | Validation (422) — transition-aware invariant |
| `NameMaxLengthExceededNotification` | `User.BuildRules.IfInsertOrUpdate` when `len(u.Name) > nameMaxLength` (pure domain constant in `domain/user.go`) | Validation (422) — **parameterized notification showcase**: carries `MaxLength int \`tvar:"maxLength"\`` so the translated message substitutes the value the domain emitted |

All embed `domain.DomainNotificationBase`. Translated in `application/translations/{ptbr,eng,esp,fra,deu,ita,nld}.go` (seven languages — mirror of the framework's seven built-in catalogs). The `application/translations/` catalogs also declare a `"User"` entry that translates the `NotificationContext.context` label across the seven languages — the framework has always translated context labels via `convert.go::ToContextDTOs`; previously the entry was missing and the literal Go struct name reached the wire envelope.

---

## Infra

### UserRepository (`infra/user_repository.go`)

Composes two framework primitives:

- **`fwinfra.BaseRepository[*User]`** embedded — provides Insert/Update/Archive/Unarchive/Delete as one-liners delegating to `Postgres`. Aggregate-aware dispatch happens transparently because User implements `AggregateRootProvider`. Unique violations (PG `23505`) turn into typed notifications via the `Constraints` map:
  ```go
  Constraints: map[string]fwinfra.ConstraintBinding{
      "users_email_active_idx": {Notification: EmailAlreadyExistsNotification{}, Field: "email"},
  },
  ```

- **`fwinfra.AggregateLoader[*User]`** in **auto-scan + inference mode** — no manual scanner, no table declaration. The loader infers the `users` table from the Go type via convention (`PluralizeSnake(PascalToSnake("User"))`); discovers columns via reflection on exported fields (`name, email, phone`); generates an explicit SELECT (`SELECT id, name, email, phone FROM users WHERE id=$1 AND deleted_at IS NULL`). Address is registered via `fwinfra.WithChild[appdomain.Address](r.loader)` — the type provides everything via reflection (`addresses` table, columns, FK `user_id`).

`FindArchivedByID` added to implement `domain.ArchivedFinder[*User]` — the `UnarchiveCommandHandler` uses it to hydrate the archived aggregate before dispatch, ensuring the cascade SQL sees the children typeNames via `root.AllAggregateItems()`.

Result: zero scanners, zero table/column/FK declarations in the Repository. For non-trivial queries, `WithRootScanner`/`WithChildScanner` are still available and coexist with auto by typeName.

### Views (`infra/views.go`)

```go
fwinfra.View("users").
    Root("users").
    EmbedMany("addresses", fwinfra.From("addresses").On("user_id"))
```

- **Collection in Mongo:** `"users"`
- **Root table in Postgres:** `users`
- **Embed many in field `addresses`**: query `addresses WHERE user_id = root.id AND deleted_at IS NULL`

`UserView()` is called **only once** in `bootstrap.NewUsersFeature(d)` (in `package main` at `bootstrap/users_feature.go`) and the pointer lives as a field of `UsersFeature`. The same pointer is consumed by `Views()` (which `bootstrap.Run` aggregates into `NewSyncEngine`) and by `Mount()` (passed to `web.MountUsers`).

### Aliases in imports

In `infra/user_repository.go` you need to import `omnicore/domain` (framework) AND `omnicore-example-users/domain` (own) — name collision. Convention in this service:

- `domain` (no alias) → framework
- `appdomain` → this service
- `fwinfra` → framework infra

---

## Application

### Commands (`application/commands/`)

Each file co-locates input + output of the same use case: Command + hydration method (`ToEntity`/`ApplyTo`/`ApplyPartiallyTo`) on the way in AND `Cmd.FromEntity(ctx, T) Result` on the way out — both methods sit on the **Command** struct. Result is a pure data struct (no methods) declared in the same file. Commands do not carry JSON tags — wire format lives in `web/requests/`.

| File | Command | Type | Hydration (input) | `FromEntity(ctx, *User) Result` (output, on Cmd) |
|---|---|---|---|---|
| `insert_user.go` | `InsertUserCommand` | `pipeline.CommandBase` | `ToEntity(ctx) *User` — creates User + `u.AddAddress(addr, nil)` per address | `InsertUserResult{ID, Name, Email, Phone}` |
| `update_user.go` | `UpdateUserCommand` | `pipeline.CommandBaseWithID` | `ApplyTo(ctx, *User)` — replace root fields + `u.ReplaceAddresses(addrs)` | `UpdateUserResult{ID, Name, Email, Phone}` |
| `patch_user.go` | `PatchUserCommand` | `pipeline.CommandBaseWithID` | `ApplyPartiallyTo(ctx, *User)` — apply only non-nil fields | `PatchUserResult{ID, Name, Email, Phone}` |
| `archive_user.go` | `ArchiveUserCommand` | `pipeline.CommandBaseWithID` | `ApplyTo(ctx, *User)` — no-op in this showcase; hook for ctx→authz translation | none — endpoint uses `fwresults.None` default |
| `unarchive_user.go` | `UnarchiveUserCommand` | `pipeline.CommandBaseWithID` | `ApplyTo(ctx, *User)` — no-op in this showcase; hook for ctx→authz translation | none — endpoint uses `fwresults.None` default |
| `delete_user.go` | `DeleteUserCommand` | `pipeline.CommandBaseWithID` | `ApplyTo(ctx, *User)` — no-op in this showcase; hook for ctx→authz translation | none — endpoint uses `fwresults.None` default |

**ctx flow into the application layer:** `Request.ToCommand()` is body-only (no ctx). The application layer receives the request `*AppContext` via the handler's `Handle(ctx, cmd)` and forwards it to the Command's mapper method (`ToEntity(ctx)`, `ApplyTo(ctx, t)`, `ApplyPartiallyTo(ctx, t)`). The Command is the only layer that may translate ctx into business-named entity fields. This example does NOT exercise the authz hook yet — the methods accept ctx and ignore it; a future round adds a `User.OwnerUserID` field + transient setter, then BuildRules' `IfUpdate` validates `Old(u).OwnerUserID == u.RequestingOwnerID` with `actionName == "GetArchivable"` branching for the archive verbs (Round 2 of the framework already wires the IfUpdate dispatch for Archive/Unarchive).

**Authorization — three layers exercised by this service.** The framework's authz model has three concentric surfaces; this example exercises all three:

1. **Layer 1 — declarative gate (transport)**: every canonical route in `web/user_routes.go` AND every manual route in `web/user_custom_routes.go` is annotated with `fwopenapi.RequirePermission("users:<verb>")`. Matrix: POST/PUT/PATCH → `users:write`; DELETE → `users:delete`; PATCH archive/unarchive → `users:archive`; GET list/byID → `users:read`. The `/whoami`, `/showcase/*`, `/echo/*` routes declare `RawSpec.Public:true` so the boot scan respects them as the exception. Under `APP_PROFILE=prd-authz`, the runtime gate enforces and the spec renders the `**Required permission:** \`<p>\`` suffix on each route's description. Under `dev` (`auth.mode: disabled`) and under `prd` (jwt, no authz block), the runtime gate no-ops AND the description suffix is suppressed — the spec never claims a constraint the server is not honoring. The values still live on `Spec.RequiredPermission` for codegen/introspection in every profile.
2. **Layer 2 — programmatic owner-check (domain)**: `domain/user.go` carries transient fields `RequestingPrincipalEmail` + `RequestingPrincipalIsAdmin` (both `transient:"-"` — domain's own declaration that the field is runtime-only, so the framework's reflection-based persister skips them); `BuildRules.IfUpdate` checks them when `actionName == "GetArchivable"`. Rule: "the JWT email claim must match the persisted User's email, unless the principal carries `users:admin`" (super-admin bypass via `*:*`). The transient fields are populated by `application/commands/archive_user.go::ApplyTo(ctx, u)` — the canonical place to translate `ctx.Identity()` into business-named fields. Tolerant of nil Identity (degraded "trust" mode under `auth.mode=disabled`).
3. **Layer 3 — tenant scoping**: deliberately NOT exercised in this example (the User aggregate has no `tenant_id` column). The pattern would live in `Query.ToCriteria(ctx)` (read overlay) + the Command mapper + `BuildRules` (write invariant). The Phase 5 plumbing is wired and ready: setting `auth.authorization.tenant: {enabled: true, required: true}` in a future profile would activate the middleware claim-presence check immediately.

Full description in [`../omnicore/CLAUDE.md`](../omnicore/CLAUDE.md) section "Authorization". Anyone adding a new endpoint plugs Layer 1 via `RequirePermission`, Layer 2 via `BuildRules`, Layer 3 via `ToCriteria` / Command mapper — never into `infra/`.

`AddressInput` (DTO shared between the canonical Insert/Update Commands) lives in `application/dtos/address_input.go` — co-located with the application layer, separated from the Commands that use it to anticipate other shared DTOs such as PaginationInput, FilterInput, etc. The manual showcase has its own `AddressInputCustom` in `address_input_custom.go` — the two surfaces share nothing above `domain/`.

None of these Commands has `Handle`. They are consumed by the framework's **Auto Command Handlers** (`handlers.InsertCommandHandler[*User, *InsertUserCommand, commands.InsertUserResult]`, `handlers.PartialUpdateCommandHandler[*User, *PatchUserCommand, commands.PatchUserResult]`, etc.) wired in `web/user_routes.go`. Each handler struct just carries `Repo` and an optional `Service` — no `Auditor`, no `Project` field. Audit emission is automatic via `infra.Postgres` (configured at boot from `audit.destinations`); handlers never thread an auditor. The projection lives on the Cmd as `cmd.FromEntity(ctx, T) TResult` (symmetric with `cmd.ToEntity`/`ApplyTo` on the input side); bodyless verbs (Archive/Unarchive/Delete) declare `FromEntity` returning `fwresults.None{}`. **Zero manual handlers** — all update/patch/archive logic fits in commands + Entity.

### Request DTOs (`web/requests/`)

JSON wire format of write endpoints + query-string wire format of read endpoints. Each write file co-locates input + output of the same use case: Request + `ToCommand()` on the way in, Response + `FromResult(Result) Response` on the way out:

| File | Request DTO | Boundary | Response (co-located, wire format) |
|---|---|---|---|
| `insert_user_request.go` | `InsertUserRequest` | `ToCommand() *commands.InsertUserCommand` | `InsertUserResponse{id, name, email, phone}` + `FromResult(commands.InsertUserResult) InsertUserResponse` |
| `update_user_request.go` | `UpdateUserRequest` | `ToCommand() *commands.UpdateUserCommand` | `UpdateUserResponse{id, name, email, phone}` + `FromResult(commands.UpdateUserResult) UpdateUserResponse` |
| `patch_user_request.go` | `PatchUserRequest` | `ToCommand() *commands.PatchUserCommand` | `PatchUserResponse{id, name, email, phone}` + `FromResult(commands.PatchUserResult) PatchUserResponse` |
| `address_request.go` | `AddressRequest` | `ToAddressInput() dtos.AddressInput` | n/a (Address has no own endpoint) |
| `find_users_by_params_request.go` | `FindUsersByParamsRequest` | `ToQuery(criteria) *queries.FindUserByParamsQuery` | `FindUsersByParamsResponse{id, name, email, phone, addresses[]}` — every field at every depth is `*T` (or a slice) with `,omitempty` because the Request declares `?fields=` and the framework's boot guard enforces the sparse-render contract; projected via `fwresponses.AutoFromDoc[FindUsersByParamsResponse]` |
| `find_user_by_id_request.go` | `FindUserByIDRequest` | `ToQuery() *queries.FindUserByIDQuery` | `FindUserByIDResponse{id, name, email, phone, addresses[]}` projected via `fwresponses.AutoFromDoc[FindUserByIDResponse]` |
| `find_user_by_email_custom_request.go` | `FindUserByEmailCustomRequest` (Email `path:"email"`) | `ToQuery(criteria) *queries.FindUserByEmailQuery` | `FindUserByEmailCustomResponse{id, name, email}` — every field `*string,omitempty` for symmetry with the list twin — projected at the route via `fwresponses.AutoFromDoc[FindUserByEmailCustomResponse]` |
| `find_users_custom_request.go` | `FindUsersCustomRequest` (filter tags + `?sort=` / `?fields=` / `?search=` / `?onlyTotal=` opt-in) | `ToQuery(criteria) *queries.FindUsersCustomQuery` | `FindUsersCustomResponse{id, name, email}` — every field `*string,omitempty` because the Request opts into `?fields=`; the framework's `QueryParser` boot guard enforces the sparse-render contract — projected at the route via `fwresponses.AutoFromDoc[FindUsersCustomResponse]` |

**Request ≡ Command shape ruler** (write side): identical shape field by field on both sides — mandatory fields as `string`, optional as `*string`. `ToCommand()` is pure assignment with no normalization. Consumer sends `"phone": ""` → `Request.Phone = *""` → `Command.Phone = *""` → domain decides whether to reject. The semantic distinction comes from the HTTP status (400 Schema vs 422 Validation), not from silent conversion at the boundary.

**`FindUsersByParamsRequest` allowlist** (read side): the struct tags `query:"X" filter:"ops"` declare which fields are filterable and which operators they accept (`eq`, `in`, `nin`, `ne`, `gte`, `lte`, `gt`, `lt` from `fwweb.Op*` constants). Pagination/control keys (`limit`, `after`, `before`, `sort`, `fields`, `search`, `archived`) carry only the `query:"..."` tag. `HandleQueryWithParams` walks the query string, validates against the tag-declared schema (cached by `reflect.Type`), assembles a `queries.ReadCriteria`, and calls `ToQuery(criteria)` — pure body mapping at the web boundary. AppContext-derived security overlays (tenant_id from JWT in the future) layer onto the criteria inside `Query.ToCriteria(ctx)` consumed by the handler — Query is the only layer below the web boundary that may consume ctx on the read side.

**`FindUserByIDRequest`** declares only `IncludeArchived *bool query:"includeArchived"` — the single reserved query parameter on by-id endpoints. Any other query-string key produces 400 at the wrapper.

**Read-side Response (projector) — same rule on both surfaces.** Every GET wrapper takes a mandatory projector `func(map[string]any) R`. Both surfaces pair with `fwresponses.AutoFromDoc[FindXxxResponse]` — the framework's tag-driven default that consumes `json:"<wire>"` for the outgoing JSON name and the optional `view:"<docKey>"` for the source-key override. The manual showcase routes (`GET /showcase/users-custom`, `GET /showcase/users-custom/:email`, `GET /showcase/users-custom/:email/addresses/:addressId`) use the SAME `AutoFromDoc[R]` projector as the canonical — projection is shared infrastructure, not a wrapper detail. The "manual" in manual showcase applies to the orchestration steps (`Bind().Body() → BindPath → QueryParser → Dispatch → RespondWithSuccess / RespondPaged`), not to hand-rolling a projector that does the same thing as `AutoFromDoc`. Declare a consumer `R{}.FromDoc` method only when the projection needs logic AutoFromDoc cannot express (derived fields, conditional shaping, ctx-aware projection). Consumers that genuinely want the raw Mongo doc on the wire pass `fwresponses.RawDoc` instead. The manual surface gets the same allowlist enforcement + sparse-render boot guard as the canonical via `fwweb.NewQueryParser[Req, Resp]` constructed at `MountUsersCustom` time — unknown keys produce the canonical 400 envelope, and a Response that violates `*T + ,omitempty` recursively panics at boot (see "Manual showcase" Read side).

**Why `ZipCode` does not need an explicit `view:` tag.** The framework's Composer writes Postgres column names verbatim to the Mongo doc — `zip_code`, not `zipCode`. The framework projector (`AutoFromDoc[R]`) and the projection schema (used by `?fields=` translation) both fall back to `domain.PascalToSnake(<json name>)` when no `view:` tag is declared. So `json:"zipCode"` maps automatically to doc key `zip_code` on both sides (read projection and `?fields=addresses.zipCode` → `{"addresses.zip_code":1}`). Declare `view:"<key>"` only for exotic schemas the convention does not cover (legacy column names, vendor-shaped projections).

**Sparse responses on `GET /users`.** `FindUsersByParamsRequest` declares `Fields *string query:"fields"`, so the wrapper's boot guard enforces the sparse-render contract on `FindUsersByParamsResponse` + `FindUsersByParamsAddressOutput`: every exported field at every depth is `*T` (or a slice) with `,omitempty`. Calling `GET /users?fields=name,addresses.city` returns `{"name":"…","addresses":[{"city":"…"}]}` — every other column is stripped at Mongo and elided on the wire. `id` is auto-excluded (`_id:0` added to projection) when not requested. `FindUserByIDResponse` does NOT opt into `?fields=` and keeps the lenient contract (mix of `string` + `*string` + `[]T`) — the canonical example deliberately covers both shapes (one endpoint with sparse mode, one without) to showcase that the guard is opt-in per Request DTO.

**`AppContext` thread-through**: all wrappers (`HandleCommandWithBody{,ID}`, `HandleCommandWithID`, `HandleQueryWith{Params,ID}`) populate `appCtx.SetParent(c)` before Dispatch — `AppContext` implements `context.Context`, so request cancellation propagates all the way down to `ViewReader.ReadPage`/`ReadByID` and to any Repository call that takes a context.

### PUT vs PATCH

| Verb | Command | Handler | Body |
|---|---|---|---|
| **PUT `/users/:id`** | `UpdateUserCommand` (non-pointer fields; `ApplyTo` replaces everything + `u.ReplaceAddresses` for addresses) | `handlers.UpdateCommandHandler` (embeds `pipeline.FullBody`) | **Strict** — wrapper requires ALL exported Cmd fields. Missing field → 422 `RequiredFieldNotification`. |
| **PATCH `/users/:id`** | `PatchUserCommand` (fields `*string` tri-state; `ApplyPartiallyTo` applies only non-nil) | `handlers.PartialUpdateCommandHandler` (no marker) | **Lenient** — partial body OK; missing fields preserve the current value. Empty body → 200 noop. |

`PatchUserCommand` does NOT declare `archived`. State transitions use dedicated `PATCH /:id/archive` and `PATCH /:id/unarchive` (aggregate-aware, cascade addresses).

**Address operations in PATCH:** intentionally NOT supported. Partial mutations of the address collection need a richer API. To touch an address, use PUT.

### Aggregate-aware archive

`PATCH /:id/archive` and `PATCH /:id/unarchive` both use Auto handlers (`ArchiveCommandHandler` / `UnarchiveCommandHandler`) that load the full aggregate (`FindByID` + `GetArchivable/GetUnarchivable` attaches `*aggregateMeta`) and cascade children:

- Archive → `UPDATE addresses SET deleted_at = NOW() WHERE user_id = $1` in a single TX
- Unarchive → restores all archived addresses for that user

Lenient wrappers — empty body is OK (`Content-Length: 0` accepted). Low-level constructors `domain.NewArchivable`/`NewUnarchivable` remain available in the framework as primitives, but the example doesn't use them — standard orchestration is via aggregate-aware Auto handler.

---

## Translations (`application/translations/`)

Seven modules: `PTBR()`, `ENG()`, `ESP()`, `FRA()`, `DEU()`, `ITA()`, and `NLD()` — mirror the 7 built-in languages of the framework (`CorePTBR`/`CoreENG`/`CoreES`/`CoreFR`/`CoreDE`/`CoreIT`/`CoreNL`). Each one implements `translation.Module` (Language + Translations map). `bootstrap.Run` registers automatically via `Wiring.Translations`:

```go
Translations: []translation.Module{apptrans.PTBR(), apptrans.ENG(), apptrans.ESP(), apptrans.FRA(), apptrans.DEU(), apptrans.ITA(), apptrans.NLD()},
```

22 keys covered in each language:
- 9 custom notifications (8 invariants + `NameMaxLengthExceededNotification` carrying the `{maxLength}` placeholder for the parameterized-notification showcase).
- 1 context label entry (`"User"`) translated alongside notifications by the framework's convert.go.
- 12 field labels (3 root: `UserNameField`/`UserEmailField`/`UserPhoneField`; 9 AVO: `AddressLabelField`/`AddressStreetField`/`AddressNumberField`/`AddressComplementField`/`AddressNeighborhoodField`/`AddressCityField`/`AddressStateField`/`AddressZipCodeField`/`AddressCountryField`). Declared via `label:"<catalogKey>"` struct tags on `domain/user.go` + `domain/address.go`. The framework's `Rules.AddNotification` resolves the tag at emit and surfaces the translated string on `MessageDTO.FieldLabel`; the auditor stamps the catalog key on `FieldChange.FieldLabelKey` for render-at-read. `RequiredFieldNotification` and other kernel keys are provided by the framework's seven `Core*` modules.

---

## Web (`web/*_routes.go`)

Routes are split across files by responsibility so each file stays focused on one concern:

| File | Mount entry point | What it owns |
|---|---|---|
| `user_routes.go` | `MountUsers(app, repo, svc, view, deps)` | The User aggregate's CRUD + queries — strictly `/users/*` |
| `user_custom_routes.go` | `MountUsersCustom(app, repo, svc, deps)` | Manual showcase of the same aggregate under `/showcase/users-custom/*` (write + read) |
| `whoami_routes.go` | `MountWhoami(app, deps)` | `GET /whoami` — `AppContext.Identity()` demo |
| `keycloak_routes.go` | _(handlers only; consumed by `MountShowcase`)_ | Three Keycloak demo handlers |
| `showcase_routes.go` | `MountShowcase(app, kc, echo, deps)` | `/showcase/keycloak/*` + `/showcase/httpclient/*` |
| `echo_routes.go` | `MountEcho(app, deps)` | `/echo/*` in-process upstream for `/showcase/httpclient/*` |
| `respond.go` | _(shared helper)_ | `respondWithError` envelope for non-domain failures |

`UsersFeature.Mount` calls `MountUsers` and nothing else; `ShowcaseFeature.Mount` calls `MountWhoami` + `MountEcho` + `MountShowcase` + `MountUsersCustom`. The default bootstrap injects the `Recover`, `Logger`, `AppContextMiddleware` middlewares (plus `AuthMiddleware` when `auth.mode: jwt`), the `GET /health` route, and — when `Wiring.OpenAPI != nil` — the `GET /openapi.json` + `GET /docs` documentation routes. None of those appear in this table.

Every route registers through `openapi.Mount` (canonical + manual with Pipeline) or `openapi.MountRaw` (free-form / vendor-shaped). When `Wiring.OpenAPI` is unset, `d.OpenAPIRegistry` is nil and both helpers short-circuit to a plain Fiber `group.Add` — the routes still work and the file diff is zero. Endpoints with body use the spec-aware siblings `fwweb.HandleCommandWithBody{,ID}Spec(d.Pipeline, requests.XxxRequest{}, requests.XxxResponse{}.FromResult, handler, status)` which return `(handler, RouteSpec)`. Endpoints without body (Archive/Unarchive/Delete) use `fwweb.HandleCommandWithIDSpec(d.Pipeline, fwresponses.NoBody, handler, status)` for the no-data default. Read endpoints use `fwweb.HandleQueryWith{Params,ID}Spec(d.Pipeline, requests.XxxRequest{}, projector, handler)`.

**`/users/*` — User aggregate (mounted by `MountUsers`):**

| Method | Path | Wrapper | Request DTO | Handler + Result | Wire success body |
|---|---|---|---|---|---|
| POST | `/users` | `HandleCommandWithBody` | `InsertUserRequest` | `InsertCommandHandler[*User, *InsertUserCommand, commands.InsertUserResult]` | 201 with `InsertUserResponse` |
| PUT | `/users/:id` | `HandleCommandWithBodyID` | `UpdateUserRequest` | `UpdateCommandHandler[*User, *UpdateUserCommand, commands.UpdateUserResult]` — **strict (marker `FullBody`)** | 200 with `UpdateUserResponse` |
| PATCH | `/users/:id` | `HandleCommandWithBodyID` | `PatchUserRequest` | `PartialUpdateCommandHandler[*User, *PatchUserCommand, commands.PatchUserResult]` — lenient | 200 with `PatchUserResponse` |
| PATCH | `/users/:id/archive` | `HandleCommandWithID` | — | `ArchiveCommandHandler[*User, *ArchiveUserCommand, fwresults.None]` — aggregate-aware (cascades addresses) | 200, no `data` |
| PATCH | `/users/:id/unarchive` | `HandleCommandWithID` | — | `UnarchiveCommandHandler[*User, *UnarchiveUserCommand, fwresults.None]` — aggregate-aware (restores archived) | 200, no `data` |
| DELETE | `/users/:id` | `HandleCommandWithID` | — | `DeleteCommandHandler[*User, *DeleteUserCommand, fwresults.None]` (hard) | 204, no `data` |
| GET | `/users` | `HandleQueryWithParams` | `FindUsersByParamsRequest` + `fwresponses.AutoFromDoc[FindUsersByParamsResponse]` | `FindByParamsQueryHandler[*FindUserByParamsQuery]` (Mongo + pagination) | 200 with `[]FindUsersByParamsResponse` + `pagination` |
| GET | `/users/:id` | `HandleQueryWithID` | `FindUserByIDRequest` + `fwresponses.AutoFromDoc[FindUserByIDResponse]` | `FindByIDQueryHandler[*FindUserByIDQuery]` (Mongo via `d.ViewReader`) | 200 with `FindUserByIDResponse` / 404 |

**Response projection — Insert/Update/Patch carry custom Result+Response (the consumer decides what comes back: `{id, name, email, phone}` snapshot). Archive/Unarchive/Delete use `fwresults.None` + `fwresponses.NoBody` defaults — the wrapper detects `responses.None` at runtime and emits the success envelope without a `data` field (matches the "204 No Content"-style shape for state-transition endpoints).

**`/whoami` — auth identity demo (mounted by `MountWhoami`):**

| Method | Path | Handler | Success status |
|---|---|---|---|
| GET | `/whoami` | reads `AppContext.Identity()` — returns the authenticated subject, or the anonymous placeholder under `auth.mode: disabled` | 200 |

**`/showcase/*` — framework demos (mounted by `MountShowcase`):**

| Method | Path | Handler | Success status |
|---|---|---|---|
| GET | `/showcase/keycloak/realm` | `KeycloakService.GetRealmInfo` — OIDC discovery, anonymous, response cached per YAML TTL | 200 / 502 |
| GET | `/showcase/keycloak/admin/:id` | `KeycloakService.FetchUser` — admin REST via `oauth2-client-credentials`; 404 path maps to `ErrUserNotFound` via `acceptableStatus: [404]` | 200 / 404 / 502 |
| GET | `/showcase/keycloak/tenant/whoami` | `KeycloakService.WhoamiTenant` — `credentials-exchange` with `requestFieldsFromCtx`; per-identity token cache | 200 / 400 / 502 |
| GET | `/showcase/httpclient/download-stream/:size` | `EchoService.DownloadStream` — response as `StreamResponse`; caller copies the body | 200 / 502 |
| POST | `/showcase/httpclient/upload-stream` | `EchoService.UploadStream` — request body piped via `http:"body,stream"` | 200 / 502 |
| POST | `/showcase/httpclient/multipart` | `EchoService.UploadMultipart` — `Multipart` value via `http:"body,multipart"` | 200 / 502 |
| GET | `/showcase/httpclient/sse` | `EchoService.SubscribeEvents` — drains the framework's EventSource pump | 200 / 502 |
| POST | `/showcase/httpclient/signed` | `EchoService.SignedRoundTrip` — exercises HMAC signing end to end | 200 / 502 |
| POST | `/showcase/httpclient/with-config-override` | `EchoService.WithConfigOverride` — `CallConfig.Method` + `CallConfig.Path` runtime override | 200 / 502 |
| POST | `/showcase/httpclient/inline-bearer` | `EchoService.InlineBearerRoundTrip` — `CallConfig.InlineAuth.Bearer` runtime credential | 200 / 502 |

**`/echo/*` — in-process upstream for the httpclient demos (mounted by `MountEcho`):**

| Method | Path | Handler | Success status |
|---|---|---|---|
| GET | `/echo/stream/:size` | Writes N bytes (capped at 16 MiB) so the consumer can copy via `StreamResponse.Body` | 200 / 400 |
| POST | `/echo/upload` | Replies with `{received_bytes, content_type}` | 200 |
| POST | `/echo/multipart` | Parses `multipart/form-data`, replies with fields + files | 200 / 400 |
| GET | `/echo/sse` | Streams three SSE events (`event`, `id`, `data`, `retry`) and closes | 200 |
| POST | `/echo/signed` | Echoes the framework-injected `X-Date` / `X-Content-SHA256` / `X-Signature` / `X-Key-Id` / `Authorization` headers it observed | 200 |

**`/showcase/users-custom/*` — manual showcase of the User aggregate (mounted by `MountUsersCustom`):**

The exact same User aggregate the canonical `/users/*` surface persists, exposed under a parallel surface that hand-rolls every layer above `domain/`. Identifier in the path is the user's **email** (not the UUID); request bodies for PUT/PATCH omit the `Email` field because that path segment is the immutable key (rename via DELETE + POST). All writes succeed against the same `users` + `addresses` tables — POSTing here and GETing the canonical `/users/:id` returns the same persisted state.

| Method | Path | Handler | Body | Success status |
|---|---|---|---|---|
| POST | `/showcase/users-custom/` | `InsertUserCustomCommandHandler` — ToEntity → GetInsertable → Orchestrator.Insert → SetID → cmd.FromEntity(ctx, user) | `InsertUserRequest` (reused) | 201 with `UserCustomResponse` (full body) |
| PUT | `/showcase/users-custom/:email` | `UpdateUserCustomCommandHandler` — FindByEmail → GetUpdatable → Orchestrator.Update → cmd.FromEntity(ctx, user) | `UpdateUserCustomRequest` (no Email) | 200 with `UserCustomResponse` |
| PATCH | `/showcase/users-custom/:email` | `PatchUserCustomCommandHandler` — FindByEmail → GetPartialUpdatable → Orchestrator.Update → cmd.FromEntity(ctx, user) | `PatchUserCustomRequest` (no Email; lenient) | 200 with `UserCustomResponse` |
| PATCH | `/showcase/users-custom/:email/archive` | `ArchiveUserCustomCommandHandler` — FindByEmail → GetArchivable → Orchestrator.Archive | `UserCustomKeyRequest` (shared, bodyless — only `Email path:"email"`) | 200 No Body |
| PATCH | `/showcase/users-custom/:email/unarchive` | `UnarchiveUserCustomCommandHandler` — FindArchivedByEmail → GetUnarchivable → Orchestrator.Unarchive | `UserCustomKeyRequest` (shared) | 200 No Body |
| DELETE | `/showcase/users-custom/:email` | `DeleteUserCustomCommandHandler` — FindByEmail → GetDeletable → Orchestrator.Delete | `UserCustomKeyRequest` (shared) | 204 No Content |
| GET | `/showcase/users-custom/:email` | `FindUserByEmailCustomQueryHandler` — ReadPage with Filter[email]=<value>, Limit=1 | `?includeArchived=true` optional (allowlist via the route's `fwweb.NewQueryParser[FindUserByEmailCustomRequest, FindUserByEmailCustomResponse]`) | 200 with `FindUserByEmailCustomResponse{id,name,email}` (reduced; `*string,omitempty`) / 404 |
| GET | `/showcase/users-custom` | `FindUsersCustomQueryHandler` — ReadPage with parsed criteria | `?includeArchived` `?limit` `?after` `?before` `?name` `?email` `?sort` `?fields` `?search` `?onlyTotal` (allowlist + sparse-render boot guard + sort opt-in slog.Warn via the route's `fwweb.NewQueryParser[FindUsersCustomRequest, FindUsersCustomResponse]` — unknown keys → 400) | 200 with `[]FindUsersCustomResponse{id,name,email}` (reduced; `*string,omitempty`) + `pagination` block |

`/whoami` is the canonical demo of consuming `AppContext.Identity()` directly: under `auth.mode: disabled` the response carries `{"subject":"anonymous","authenticated":false}`; under `auth.mode: jwt` the framework's `AuthMiddleware` populates `Identity` from the bearer token and the body reflects the JWT subject and issuer.

The `/showcase/*` group is the showcase of the outbound `httpclient` subsystem. All handlers follow the same shape: fetch `fwweb.AppContext(c)`, `SetParent(c)`, delegate to a vendor service struct (`KeycloakService` / `EchoService`), return via `fwweb.RespondWithSuccess` or `respondWithError`. None of them imports `omnicore/infra/httpclient` — the package is encapsulated inside `infra/external/keycloak_service.go` and `infra/external/echo_service.go` (see [Outbound HTTP](#outbound-http) below).

The `/echo/*` group is the in-process upstream that `/showcase/httpclient/*` consumes. It is a producer-side shim with no domain logic, no persistence, no auth — it just echoes bytes / parses multipart / streams SSE events / captures signing headers. Keeping the producer in the same binary makes the streaming and signing showcases self-contained: the `echo` and `echo-signed` httpClient services point at `localhost:8080` and the QA suite needs no new docker-compose container.

`GET /health` comes from the framework — any OmniCore service responds 200 on that route without programming anything. For a custom health (DB ping etc), expose another route (`/healthz`, `/ready`) via feature or `BeforeServe`.

**Error status codes (via notification `Semantic`):**
- **Schema** → 400 Bad Request:
  - `SchemaViolationNotification` — malformed JSON or type mismatch (`"age": "twenty"` when int)
  - `RequiredFieldNotification` with semantic Schema — emitted by the wire wrapper when a PUT arrives without all fields of `UpdateUserRequest`
- **Validation** → 422 Unprocessable Entity (default; domain rules in `BuildRules`)
- `RecordNotFoundNotification` (kernel) → 404
- `EmailAlreadyExistsNotification` → 409 Conflict (override `Semantic()` on the notification)

The error body has a single shape (`Response{success, status, description, errors}`) for both 400 and 422 — the consumer parses a single envelope.

---

## Manual showcase (`/showcase/users-custom/*`)

Parallel surface that exercises the **same** User aggregate the canonical `/users/*` persists, with every layer above `domain/` hand-rolled. Where the canonical surface composes framework wrappers (`HandleCommandWithBody{,ID}` + Auto Command Handlers + `BaseAggregateRepository` + `HandleQueryWith{Params,ID}`), the manual surface writes out each step so a reader can trace the lifecycle the wrappers hide. Both surfaces operate on the same `users` + `addresses` tables and the same Mongo view — POSTing here and GETing the canonical `/users/:id` returns the same persisted state.

The motivation is to **explode** the wrapper internals into visible Fiber-handler code so devs can opt out of any single layer with full knowledge of what they lose. The wrappers hide a chain of steps; the manual showcase makes every step visible: `c.Bind().Body()` (with Schema notification when malformed) → `BindPath` (path-tag binding) → `QueryParser.Parse` (allowlist + projection-schema translation) → `req.ToCommand` / `req.ToQuery` (web→application boundary) → `pipeline.Dispatch` (translator + recover + Result envelope) → success branch via `RespondWithSuccess` / `RespondPaged` (canonical envelope assembly + projection per item) / failure branch via `RespondFromResult` (Semantic→HTTP status mapping). Reading the manual handlers side-by-side with the canonical wrappers shows exactly which step lives where and which trade-offs each manual choice carries.

**What manual does NOT mean.** "Manual" applies to the orchestration steps the wrappers hide. It does NOT mean re-implementing primitives the framework already exposes — projection (`fwresponses.AutoFromDoc[R]`), pagination envelope assembly (`fwweb.RespondPaged`), schema violation envelope (`fwweb.RespondSchemaViolation`), Mongo doc extraction — those are shared infrastructure regardless of which path mounted the route. A "manual FromDoc" that just walks `doc["id"]`, `doc["name"]`, `doc["email"]` adds nothing on top of `AutoFromDoc[R]` and would be dumb duplication. Declare a custom `FromDoc` only when the projection needs logic AutoFromDoc cannot express (derived fields computed from multiple doc keys, conditional projection, ctx-aware shaping).

**Result intermediate is mandatory, not optional.** The manual write handlers all return application-layer DTOs (`commands.UserCustomResult` for Insert/Update/Patch/ChangeAddress, `fwresults.None` for Archive/Unarchive, `struct{}` for Delete). The route projects via `responses.FromResult(result.Value())` for body verbs and `RespondWithStatus` for state transitions. The domain entity never crosses into `web/` — same decoupling the canonical surface achieves via the Cmd's `FromEntity` method, just with the orchestration written out around it. Verb-by-verb shapes match the canonical: 200 with body for Insert/Update/Patch/ChangeAddress, 200 without body for Archive/Unarchive, 204 for Delete.

### What stays canonical, what goes manual

| Layer | Canonical `/users/*` | Manual `/showcase/users-custom/*` |
|---|---|---|
| `domain/` | User, Address, BuildRules, AggregateRoot | **same code — domain is invariant across both surfaces** |
| `application/commands/` | `Insert/Update/Patch/Archive/Unarchive/DeleteUserCommand` (+ per-endpoint `Insert/Update/PatchUserResult` co-located in the same files) | All six have `*CustomCommand` twins. Insert mirrors the canonical shape; the other five add an `EmailKey` slot (path identifier) and the PUT/PATCH twins drop `Email` from the mutable surface. A SHARED `UserCustomResult` (+ `AddressCustomResult`) in `user_custom_result.go` carries the snapshot returned by Insert/Update/Patch — the canonical's per-endpoint Result granularity already covers that pattern, so the manual showcase collapses it to one struct to demonstrate that the Result-intermediate principle composes with a shared shape |
| `application/dtos/` | `AddressInput` (DTO consumed by canonical Insert/Update commands) | `AddressInputCustom` — dedicated twin so only `domain/` is reused across surfaces |
| `application/handlers/` | framework's generic `handlers.InsertCommandHandler[T,*Cmd,TResult]` etc. | `apphandlers.{Insert,Update,Patch,Archive,Unarchive,Delete}UserHandler` written out |
| `infra/user_repository.go` | `BaseAggregateRepository[*User]` (writes + FindByID/FindArchivedByID via promotion) | — |
| `infra/user_custom_repository.go` | — | `UserCustomRepository` — 1-line write delegations + custom `FindByEmail` / `FindArchivedByEmail` SQL |
| `web/user_routes.go` | `fwweb.HandleCommandWithBody{,ID}` + `HandleCommandWithID` | — |
| `web/user_custom_routes.go` | — | Plain Fiber handlers: `Bind().Body() → AppContext → ToCommand → Dispatch → switch result` |
| `web/requests/` | `Insert/Update/PatchUserRequest` + `AddressRequest` (canonical wire DTOs) | `Insert/Update/PatchUserCustomRequest` + `AddressCustomRequest` (dedicated wire DTOs — Update/Patch drop `Email` from the body, Insert mirrors the canonical body shape) |
| `web/responses/` | per-endpoint `Insert/Update/PatchUserResponse` **co-located in `web/requests/xxx_user_request.go`** alongside the Request DTOs (same rule for canonical reads: `FindUserByIDResponse` / `FindUsersByParamsResponse` co-located with their Requests); Archive/Unarchive/Delete use the framework's `fwresponses.NoBody` default; GETs project via `fwresponses.AutoFromDoc[R]` (tag-driven default) | `UserCustomResponse` lives in `web/responses/` because it is shared across the three body verbs (Insert/Update/Patch) and `FromResult(commands.UserCustomResult)` is the pure Result → wire mapper (no domain imports — application Result is the contract); Archive/Unarchive align with the canonical and use `fwresponses.None` (route emits envelope without `data`); Delete returns 204 No Content; manual GETs follow the same co-located rule as the canonical (`FindUserByEmailCustomResponse` + `FindUsersCustomResponse` co-located with their Requests) AND project through the SAME `fwresponses.AutoFromDoc[R]` the canonical uses — no hand-rolled `FromDoc`, projection is shared infrastructure |
| `application/queries/` | `FindUserByIDQuery`, `FindUserByParamsQuery` | `FindUserByEmailQuery`, `FindUsersCustomQuery` |
| Read handlers | framework's generic `FindByIDQueryHandler` + `FindByParamsQueryHandler` | `FindUserByEmailCustomQueryHandler` + `FindUsersCustomQueryHandler` written out, each carrying the access-control filter seam |
| `infra/` read side | `MongoViewReader` via `d.ViewReader` (canonical) | **same** — manual surface consumes the same reader; lookup by email is a `Filter[email]=<value>` + `Limit=1` ReadPage; list is a normal paged ReadPage |
| `bootstrap/` | `UsersFeature` mounts via `MountUsers` | `ShowcaseFeature` also constructs `UserCustomRepository` + a second `UserService` and mounts via `MountUsersCustom` |

`application/handlers/ports_custom.go` declares the `UserCustomRepository` interface — `domain.Repository[*User]` extended with `FindByEmail` / `FindArchivedByEmail`. Application depends on the interface (not the concrete `*appinfra.UserCustomRepository`) so the dependency direction stays application → domain.

### Email as the public identifier

`/:email` segment is the lookup key. Email is treated as **immutable on this surface** — request DTOs for PUT and PATCH expose `Email` only via the `path:"email"` struct tag (no `json` tag), so the value comes from the URL segment, never the body. Three alternatives were considered and rejected: URL-old + body-new (silent rename — confusing), URL must equal body (useless duplication), URL wins + body ignored (contract lie). The canonical `/users/:id` (UUID-keyed) route already exists for any scenario that needs email mutation — the showcase deliberately picks the cleaner trade-off for its surface.

The domain's `EmailCannotChangeNotification` rule (in `User.BuildRules` under `IfUpdate`) keeps both surfaces honest: even the canonical PUT cannot actually rename email today; the rule blocks it. The showcase merely makes the immutability visible at the wire-DTO level.

### Path binding via `fwweb.BindPath`

Every route — body-carrying and bodyless alike — chains `fwweb.BindPath(c, &req)` so the `:email` URL segment is read into a tagged struct field instead of via `c.Params()`. Body-carrying routes (PUT, PATCH) declare an endpoint-specific Request DTO (e.g. `UpdateUserCustomRequest`) whose `Email` field carries `path:"email"` alongside the JSON body fields. Bodyless routes (Archive / Unarchive / Delete) share a single `UserCustomKeyRequest` (`web/requests/user_custom_key_request.go`) — one struct with a single `Email string \`path:"email"\`` field, reused across the three verbs. The shared DTO mirrors the response-side convention where Insert/Update/Patch reuse `UserCustomResponse`: one wire shape, one struct, multiple endpoints.

Symmetry across the whole surface is the point. Reading `c.Params("email")` directly on a route would save one line of code but leave the route's identifier outside any tagged struct — and a reverse-engineering pass (OpenAPI generator, contract diff tool, client-codegen) introspects Request types via reflection. Tagging the identifier on every route lets such a pass discover the path parameter uniformly, without grepping handler bodies, and brings the manual surface to structural parity with the canonical `/users/*` (where the framework's wrapper resolves the path identifier from its handler type instead of the DTO — different mechanism, equivalent visibility).

Body-carrying routes (POST, PUT, PATCH) chain `BindPath` right before `c.Bind().Body(&req)` so the framework first reads `c.Params("email")` into the path-tagged field, then JSON-unmarshals the body fields on top — `ToCommand` afterwards maps `req.Email` into `cmd.EmailKey`. Bodyless routes (Archive / Unarchive / Delete) chain `BindPath` alone and assemble the Command inline (`cmd := &commands.ArchiveUserCustomCommand{EmailKey: req.Email}`) — no `ToCommand` method on the shared DTO because the assembly differs per verb and is a one-liner each.

The by-email GET (`customGetUserByEmail`) also chains `BindPath` before the QueryParser's `Parse` — the path-binding and query-allowlist run as two complementary `fwweb` helpers, mirroring the structure of the canonical wrappers.

### Trade-offs deliberately accepted

The manual surface gives up three small things the canonical `HandleCommandWithBody{,ID}` wrapper provides:

1. **Schema violation typing.** Malformed JSON returns 400 with a bare envelope instead of the canonical `SchemaViolationNotification` (which is emitted by package-private framework helpers). Status and shape are compatible; only the typed `notificationKey` is missing on this path.
2. **`FullBody` marker support.** The canonical PUT enforces "all exported fields of the Request DTO must be present in the JSON" via the `FullBody` marker + reflection. The manual PUT does not — missing fields surface as 422 from `BuildRules` instead of 400 from the wire. Acceptable here because PUT/PATCH custom drop the immutable `Email` field; what's required is short enough that domain validation covers it.
3. **Boilerplate.** Each Fiber handler explicitly performs the 5-step dance the wrapper hides. Reading is the point; writing every new manual endpoint by hand is the cost.

Repository-side, `UserCustomRepository.Insert/Update/Archive/Unarchive/Delete` are **1-line delegations to `fwinfra.Postgres`** — the same primitives `BaseRepository` calls under the hood. Going further (managing `pgx.Tx` + outbox INSERT + aggregate cascade by hand) would break the framework's "outbox is atomic with the write" invariant for no didactic gain — that transaction engineering already lives inside `fwinfra.Postgres` and is not part of what "manual" means in this showcase. The custom Repository's own SQL is confined to `FindByEmail` / `FindArchivedByEmail` + the constraint-violation translation (`mapErr` replicated because `BaseRepository.mapErr` is package-private).

### Read side

The two GET endpoints reuse the canonical `MongoViewReader` (`d.ViewReader`) and the canonical `UserView()` — no second Mongo view, no second SyncEngine subscription. What changes is the **application handler** and the **wire shape**:

- **`FindUserByEmailCustomQueryHandler`** — by-email lookup. The framework's `FindByIDQueryHandler` dispatches to `ViewReader.ReadByID` which only knows the document's primary-key path (Mongo's `_id`). The manual handler instead issues a single-item `ReadPage` with `Filter[email]=<value>` and `Limit=1`, treating an empty `Items` slice as 404 (`RecordNotFoundNotification`). The application returns the raw doc; the wire layer projects via `fwresponses.AutoFromDoc[requests.FindUserByEmailCustomResponse]` — same tag-driven default the canonical surface uses.
- **`FindUsersCustomQueryHandler`** — paged list. Returns the framework's `queries.Page` (Items + cursor envelope) verbatim; the route delegates to `fwweb.RespondPaged` which projects each item via `fwresponses.AutoFromDoc[requests.FindUsersCustomResponse]` and emits the canonical envelope (Data at top level, Pagination at top level).

Both handlers carry a **commented placeholder block** right between `q.ToCriteria(ctx)` and `Reader.ReadPage(...)` showing exactly where to inject row-level access control from `AppContext.Identity()` claims (multi-tenant scope, owner-only, business overlays, Limit caps, default sort). Note the seam now lives on **two sides**: the manual handler block (route-side adjustments such as Limit caps or default Sort) and the Query's `ToCriteria(ctx)` (Filter overlays that the canonical Auto handlers ALSO honor automatically). The canonical Auto query handlers now expose the same ctx-aware hook via `ToCriteria(ctx)` — so authz-shaped Filter reads no longer require going manual; the manual surface still exists to demonstrate the pattern + cover the cases where the lookup needs an arbitrary identifier (email) the Auto path's `SetPathID` semantic does not fit.

**Reduced wire shape.** `FindUserByEmailCustomResponse` and `FindUsersCustomResponse` carry only `id`, `name`, `email` — phone and addresses, which the canonical `GET /users/:id` and `GET /users` surfaces both expose, are dropped at the projection step. This proves wire format and view format are independent concerns: the same denormalized view can feed multiple projections. The list endpoint additionally opts into `?fields=` so the consumer can narrow the wire shape further (`?fields=name` returns `{"name":"…"}` only); the by-email endpoint keeps the reduced shape fixed (no `?fields=` opt-in today, structurally ready via the same `*string,omitempty` shape).

**Query allowlist + sparse-render guard via `fwweb.NewQueryParser` — symmetric with the canonical.** `MountUsersCustom` constructs two parsers at the top: `fwweb.NewQueryParser[requests.FindUsersCustomRequest, requests.FindUsersCustomResponse]()` for the list endpoint and `fwweb.NewQueryParser[requests.FindUserByEmailCustomRequest, requests.FindUserByEmailCustomResponse]()` for the by-email lookup. Construction runs the same boot scan `HandleQueryWithParams` runs internally on the canonical surface — the list-side parser fires the sparse-render guard on `FindUsersCustomResponse` (every field at every depth must be `*T` + `,omitempty`) AND emits the `slog.Warn("query.sort.opt-in: …")` advisory listing every sortable wire path so the operator can compare against the Mongo view's index declaration. The by-email parser doesn't opt into either reserved key, so its construction is a no-op pass-through (no guard, no warn) — keeping it on the canonical path anchors the by-email surface so a future opt-in is one tag away from getting the same guarantees. Both parsers' per-request `Parse(c)` validates against `query:`/`filter:` tags and translates `?fields=` / `?sort=` wire→doc via the projection schema (`zipCode → zip_code` etc.); unknown keys produce the canonical 400 envelope (`SchemaViolationNotification`). `?includeArchived` is supported on both endpoints — mirrors the canonical `/users/:id?includeArchived=true` semantic, the same `IncludeArchived` flag on `ReadCriteria` propagates through to the `MongoViewReader`.

**Envelope assembled by `fwweb.RespondPaged`.** The list route delegates to the framework helper after a successful Dispatch — `RespondPaged` walks the `queries.Page` and applies `fwresponses.AutoFromDoc[FindUsersCustomResponse]` once per item, then emits the canonical envelope (`Data: []FindUsersCustomResponse`, top-level `Pagination`). The by-email route uses `fwweb.RespondWithSuccess` with `fwresponses.AutoFromDoc[FindUserByEmailCustomResponse](result.Value())` for the single-item path. AutoFromDoc handles the `_id → id` fallback, the `PascalToSnake` source-key translation (so `json:"zipCode"` maps to doc field `zip_code` automatically), and the nil→empty slice normalization — same infrastructure the canonical `GET /users` + `GET /users/:id` ride on. The manual showcase deliberately reuses it instead of hand-rolling a redundant projector.

---

## Outbound HTTP

The example exercises the framework's `omnicore/infra/httpclient` subsystem end-to-end against the local Keycloak fixture. The integration is structured as:

- **YAML declaration** — `microservice.dev.yaml` carries an `httpClient` block describing services (per upstream: `baseURL`, default headers, auth provider binding, per-endpoint method/path/cache/acceptable-status) and `authProviders` (per token vendor: type, token endpoint, request fields, token cache hints).
- **Vendor adapter** — `infra/external/keycloak_service.go` is the only file in the consumer that imports `omnicore/infra/httpclient`. It exposes a small Go API (`GetRealmInfo`, `FetchUser(ctx, id)`, `WhoamiTenant(ctx, username, password)`) returning vendor-neutral types (`RealmInfo`, `KeycloakUser`, `Whoami`) and a sentinel (`ErrUserNotFound`) for the 404 path. Per-call request DTOs (`fetchUserRequest`, etc.) are package-private — never leaked to the handler.
- **Handlers** — `web/keycloak_routes.go` and `web/showcase_routes.go` declare thin Fiber handlers that fetch `AppContext`, delegate to the vendor service struct (`KeycloakService` / `EchoService`), and map errors to `respondWithError`.

### Canonical consumer pattern

```
handler (web/showcase_routes.go)
   └─ fwweb.AppContext(c).SetParent(c)
   └─ KeycloakService.<Method>(ctx, ...)                       ← infra/external/
            └─ httpclient.Call[Req, Resp](ctx, http, "service", "endpoint", req)
                     └─ middleware chain: correlation → log → auth → idempotency
                                            → cache → retry → breaker → transport
```

**Rule:** handlers depend on the vendor service struct (`*appexternal.KeycloakService`); only that struct imports `httpclient`. This keeps the wire mechanics (header propagation, token acquisition, cache keys, breaker state, retry policy) on one side of a single import boundary, and the business code on the other.

### Demo services

| YAML service | Auth provider | What it demonstrates |
|---|---|---|
| `keycloak-public` | — (anonymous) | Response cache. `GET /.well-known/openid-configuration` is cached for the YAML TTL (5m); subsequent calls return `cacheStatus: hit` and never reach Keycloak. |
| `keycloak-admin` | `kc-admin` (`oauth2-client-credentials`) | Service-account token cache. The framework acquires the bearer once via `client_credentials`, caches it under the provider name with single-flight, and reuses it for every request until expiry (TTL derived from `expires_in` minus 30s skew). 401 from upstream triggers token revocation + reacquire (`revocationOnUnauthorized: true`). Endpoint declares `acceptableStatus: [404]` so a missing user returns the typed error path instead of leaking the upstream payload. |
| `keycloak-tenant` | `kc-password-tenant` (`credentials-exchange`) | Multi-tenant password grant via `requestFieldsFromCtx`. The provider reads `tenant.username` and `tenant.password` from the request `AppContext` at acquire time, posts a form-urlencoded body to the token endpoint, extracts the bearer via `responseTokenPath`, and caches it under a SHA-256 of the per-identity values — Alice and Bob get independent cache entries. Raw credentials never leak into the cache key. |
| `echo` | — | Streaming surfaces against an in-process upstream. Carries four endpoints: `download` (`responseStream: true` → `StreamResponse`), `uploadStream` (consumes a request DTO tagged `http:"body,stream"`), `multipart` (`http:"body,multipart"` with `httpclient.Multipart`), `sse` (`responseSSE: true` → `SSEResponse`). No signing block — signing + streaming uploads is rejected at call time by the framework. |
| `echo-signed` | — (HMAC signing block instead) | HMAC request signing end to end. Declares `signing: { type: hmac-sha256, ... }` so every outbound call injects `X-Date` + `X-Content-SHA256` + `X-Signature` + `X-Key-Id` headers. The upstream (`/echo/signed`) echoes them back so the showcase handler can assert each one is populated. Also exercised by `CallConfig.InlineAuth.Bearer` so the consumer proves runtime credentials propagate as `Authorization: Bearer ...`. |

### YAML block

The `microservice.dev.yaml` declaration that drives these three services is reproduced in full under [`microservice.dev.yaml`](#microservicedevyaml) below — see the `httpClient.defaults`, `httpClient.services`, and `httpClient.authProviders` subtrees there. Two non-obvious settings:

- `defaults.cache.honorCacheControl: false` — Keycloak emits `Cache-Control: no-store` on both discovery and admin endpoints. The framework honors that hint by default, which prevents the response cache from storing. This showcase opts out so YAML TTLs govern eviction. In production, leave the default on and trust the upstream's hints.
- `kc-password-tenant.requestFieldsFromCtx: { username: tenant.username, password: tenant.password }` — the provider pulls these two values from `*AppContext` at every acquire. The handler is the only place that decides where they come from (here, query string — DEMO ONLY; production callers thread them from a vault or session). The cache key derives from a SHA-256 of the resolved values, so concurrent tenants never share a token.

### Sandbox-only environment variables

The YAML interpolation pulls these from env when set, falling back to the dev defaults otherwise:

| Variable | Default | Purpose |
|---|---|---|
| `KC_URL` | `http://localhost:8088` | Keycloak base URL (host's exposed port from `docker-compose.yml`) |
| `KC_ADMIN_CLIENT_ID` | `omnicore-users-client` | OAuth2 client id for `kc-admin` provider |
| `KC_ADMIN_CLIENT_SECRET` | `test-secret-please-change` | Matching client secret (matches `realm-export.json`) |
| `KC_TENANT_CLIENT_ID` | `omnicore-users-client` | Same client reused for password grant |
| `KC_TENANT_CLIENT_SECRET` | `test-secret-please-change` | Same secret |

The hardcoded defaults are intentional — the test realm (`devops/keycloak/realm-export.json`) ships with these exact values so `docker compose up` + `go run ./bootstrap` boots a self-contained sandbox with no extra env juggling.

### Known limitations of the showcase

- **`keycloak-admin` returns 502 in the sandbox.** The service account `service-account-omnicore-users-client` does not carry the `realm-management` `view-users` role by default, so Keycloak responds 403 to the admin REST API and the framework wraps it as a 502. The point of the endpoint is to prove the OAuth2 provider acquires + forwards the bearer (otherwise the upstream would return 401 invalid_token, not 403 insufficient permission). Granting the role in the realm export turns the path into a real 200 — kept out by default to keep the sandbox minimal.
- **Cache hit verification via slog log.** The response body has no `cacheStatus` field; the framework writes a structured log line per request with `cacheStatus=hit|miss`. The `qa/httpclient.sh` script uses wall-clock timing as a proxy (warm calls measure milliseconds vs. token-endpoint round-trips on cold) plus the slog line as the ground truth.



All infra config lives in `microservice.<profile>.yaml`. `bootstrap.Run` reads `APP_PROFILE` from the environment (required; `dev` or `prd`) and loads the matching file — this example currently ships only `microservice.dev.yaml`; a production deployment would add `microservice.prd.yaml`. `bootstrap/main.go` only calls `bootstrap.Run(Wire)` — `Wire` lives next door, in the same `package main`. Composition (translations + features) is also in `bootstrap/`.

```go
// bootstrap/main.go
package main

func main() {
    if err := bootstrap.Run(Wire); err != nil {
        log.Fatal(err)
    }
}

// bootstrap/wire.go
package main

func Wire(d bootstrap.Deps) bootstrap.Wiring {
    return bootstrap.Wiring{
        Translations: []translation.Module{apptrans.PTBR(), apptrans.ENG(), apptrans.ESP(), apptrans.FRA(), apptrans.DEU(), apptrans.ITA(), apptrans.NLD()},
        Features: []bootstrap.Feature{
            NewUsersFeature(d),
            NewShowcaseFeature(d),
        },
    }
}

// bootstrap/users_feature.go — focused on the User aggregate
package main

type UsersFeature struct {
    repo *appinfra.UserRepository
    svc  *appinfra.UserService
    view *fwinfra.ViewDefinition
}

func NewUsersFeature(d bootstrap.Deps) *UsersFeature {
    return &UsersFeature{
        repo: appinfra.NewUserRepository(d.Postgres),
        svc:  appinfra.NewUserService(d.Postgres),
        view: appinfra.UserView(), // called ONCE for the entire service
    }
}

func (f *UsersFeature) Views() []*fwinfra.ViewDefinition { return []*fwinfra.ViewDefinition{f.view} }
func (f *UsersFeature) Mount(app *fiber.App, d bootstrap.Deps) {
    appweb.MountUsers(app, f.repo, f.svc, f.view, d) // strictly /users/*
}

// bootstrap/showcase_feature.go — framework demos kept separate from the User aggregate
package main

type ShowcaseFeature struct {
    kc   *appexternal.KeycloakService
    echo *appexternal.EchoService
}

func NewShowcaseFeature(d bootstrap.Deps) *ShowcaseFeature {
    return &ShowcaseFeature{
        kc:   appexternal.NewKeycloakService(d.HttpClient),
        echo: appexternal.NewEchoService(d.HttpClient),
    }
}

func (f *ShowcaseFeature) Mount(app *fiber.App, d bootstrap.Deps) {
    appweb.MountWhoami(app)
    appweb.MountEcho(app)
    appweb.MountShowcase(app, f.kc, f.echo)
}
```

> The directory is named `bootstrap/` to mirror the framework's `omnicore/bootstrap` package (same "assemble and wire everything" intent), but because it contains the entry point all files are `package main` — no collision with `import "github.com/ClaudioSchirmer/omnicore/bootstrap"`, which is used by the name `bootstrap.` inside the files.

`UsersFeature` implements `bootstrap.ReadableFeature` (has a read side → contributes a view to the SyncEngine). Write-only features implement only `bootstrap.Feature` (no `Views()`).

Behavior `bootstrap.Run` covers automatically:

- Reads `APP_PROFILE` env (`dev`\|`prd`, required), loads `microservice.${APP_PROFILE}.yaml`, interpolates `${VAR:default}` with env vars, validates required, and rejects boot if `auth.mode=disabled` under any profile other than `dev`
- Connects Postgres + Mongo (defer Close)
- Rejects boot if wiring has no `Features` and no `BeforeServe` (nothing to serve)
- Applies pending migrations — first version 1 (outbox, embedded in the framework), then the service's `migrations/0002+`
- Builds `Translator`, `Pipeline`, `MongoViewReader`, `QueryHandler`; configures audit on the Postgres adapter via `pg.WithAudit(&cfg.Audit, logger, cfg.Auth.AuditClaims)` so every subsequent write emits the configured destinations automatically
- Imports `Wiring.Translations` into the Translator
- Collects Views from every `ReadableFeature` and rejects boot if 2 features declare the same view name (Mongo collection collision)
- Starts `SyncEngine` if at least one view was collected
- Automatically registers `GET /health`
- Calls `f.Mount(app, d)` for each feature in declaration order
- Fiber with default middlewares (`Recover`, `Logger`, `AppContextMiddleware`)
- HTTP drain in 10s on SIGINT/SIGTERM

### microservice.dev.yaml

```yaml
service: omnicore-example-users

http:
  addr: "${HTTP_ADDR::8080}"

postgres:
  dsn: "${DATABASE_URL:postgres://omnicore:omnicore@localhost:5433/users_db?sslmode=disable}"

mongo:
  uri: "${MONGO_URI:mongodb://localhost:27018}"
  database: "${MONGO_DB:users_views}"

kafka:
  brokers:
    - "${KAFKA_BROKERS:localhost:9094}"
  syncGroupId: "${SYNC_GROUP_ID:omnicore-example-users-sync}"

migrations:
  dir: ./migrations
  autoRun: true

auth:
  mode: disabled       # explicit; the framework rejects this combination under APP_PROFILE=prd

httpClient:
  defaults:
    timeout: 10s
    headers:
      User-Agent: "omnicore-example-users/1.0"
    cache:
      enabled: true
      defaultTTL: 5m
      honorCacheControl: false   # Keycloak emits no-store; override only for this showcase

  services:
    keycloak-public:
      baseURL: "${KC_URL:http://localhost:8088}"
      endpoints:
        getRealmInfo:
          method: GET
          path: /realms/omnicore-test/.well-known/openid-configuration
          cache: { ttl: 5m }

    keycloak-admin:
      baseURL: "${KC_URL:http://localhost:8088}"
      auth: { provider: kc-admin }
      endpoints:
        getUser:
          method: GET
          path: /admin/realms/omnicore-test/users/{id}
          acceptableStatus: [404]
          cache:
            ttl: 1m
            varyOn: [header:Accept-Language]

    keycloak-tenant:
      baseURL: "${KC_URL:http://localhost:8088}"
      auth: { provider: kc-password-tenant }
      endpoints:
        whoami:
          method: GET
          path: /realms/omnicore-test/protocol/openid-connect/userinfo

  authProviders:
    kc-admin:
      type: oauth2-client-credentials
      tokenEndpoint: "${KC_URL:http://localhost:8088}/realms/omnicore-test/protocol/openid-connect/token"
      clientId: "${KC_ADMIN_CLIENT_ID:omnicore-users-client}"
      clientSecret: "${KC_ADMIN_CLIENT_SECRET:test-secret-please-change}"
      tokenCache:
        source: response-field
        jsonPath: $.expires_in
        unit: seconds
        skew: 30s
      revocationOnUnauthorized: true

    kc-password-tenant:
      type: credentials-exchange
      tokenEndpoint: "${KC_URL:http://localhost:8088}/realms/omnicore-test/protocol/openid-connect/token"
      requestCodec: form-urlencoded
      requestFields:
        grant_type: password
        client_id: "${KC_TENANT_CLIENT_ID:omnicore-users-client}"
        client_secret: "${KC_TENANT_CLIENT_SECRET:test-secret-please-change}"
        scope: openid
      requestFieldsFromCtx:
        username: tenant.username
        password: tenant.password
      responseTokenPath: $.access_token
      tokenCache:
        source: response-field
        jsonPath: $.expires_in
        unit: seconds
        skew: 30s
```

`APP_PROFILE=dev` selects this file at boot. A production deployment adds a sibling `microservice.prd.yaml` (not in the repo — the maintainer ships it separately) with `auth.mode: jwt` plus `jwksUrl` / `publicKeyPem` + `issuer` + `audience` configured against a real IdP.

**Supported variables (with defaults for local docker-compose):** `HTTP_ADDR`, `DATABASE_URL`, `MONGO_URI`, `MONGO_DB`, `KAFKA_BROKERS`, `SYNC_GROUP_ID`, `KC_URL`, `KC_ADMIN_CLIENT_ID`, `KC_ADMIN_CLIENT_SECRET`, `KC_TENANT_CLIENT_ID`, `KC_TENANT_CLIENT_SECRET`, `INTEGRATION_GROUP_ID`. For an alternative path, export `OMNICORE_CONFIG_PATH` (still requires `APP_PROFILE`). `migrations.dir` is relative to CWD — always run from the service root (`APP_PROFILE=dev go run ./bootstrap`) to resolve correctly.

**Integration + shutdown blocks.** Every variant carries the new framework blocks:

- `integration.defaults` — seeds the consumer-group name (`"${INTEGRATION_GROUP_ID:omnicore-example-users-integration}"`), worker count (4), and startFrom hint (`latest`). The service currently emits no events AND consumes no events, so the empty `publishes` and `subscribes` maps result in zero runtime cost — `fwintegration.Configure` registers the singleton and `bootstrap.Run` spins no consumer goroutines. The defaults are declared so a future round adding a publisher or subscriber edits only the matching sub-block.
- `shutdown.drainTimeoutSeconds: 30` — caps the coordinated drain on SIGINT/SIGTERM. The framework runs HTTP server, integration consumer pool, and upstream subscribers' drains in parallel under the shared shutdownCtx. 30s matches the kubernetes `terminationGracePeriodSeconds` default so a pod eviction completes inside the orchestrator's window.

**AdminFeature surfaces.** The `bootstrap/admin_feature.go` struct registers two HTTP routes that drive the framework's retry primitives:

- `POST /admin/retries/upstream` — walks `d.UpstreamSubscribers` calling `RetryPendingFailures(ctx)` on each; returns `{"retried": N}`.
- `POST /admin/retries/integration` — walks `d.IntegrationRegistry.Receivers()` calling `RetryPendingFailures(ctx, pg.Pool(), pipe, logger)` on each; returns `{"retried": N}`.

Both routes sit behind `fwopenapi.RequirePermission("admin:retry")` and surface under Swagger tag `Admin`. The handlers read the registry / subscriber slice via closure at request time — by the time HTTP starts serving (after Phase Receivers + ConsumerPool.Start completed) both are fully populated. Operators expose the routes through the same JWT / claim machinery any other gated endpoint uses.

### Migrations

The schema is managed by the framework's **Migration Manager** (`golang-migrate/migrate v4` wrapper):

- **Version 1** — `0001_outbox.up.sql` — embedded in the framework, tracking in `omnicore_framework_migrations`. Creates the `outbox` table required by the Debezium Outbox Event Router.
- **Version 2** — this service's `migrations/0002_init.up.sql` — tracking in `omnicore_migrations`. Creates `users`, `addresses`, unique soft-delete-aware indexes.

Every `.up.sql` must have a `.down.sql` counterpart (validated by `mgr.ValidateDownExists()` on boot).

> Outbox SQL **no longer lives in this service.** It is injected by the framework. If another service comes up against the same Postgres with the same table, the signature is guaranteed identical (Debezium depends on it).

---

## Docker compose

4 services with non-default ports to avoid conflict with local instances:

| Service | Host port | Notes |
|---|---|---|
| `postgres` | `5433` | PG 16 with `wal_level=logical` (required by Debezium). The schema is created by the framework on Go boot — **migrations are NO LONGER mounted in `docker-entrypoint-initdb.d`** |
| `mongo` | `27018` | Mongo 7, no auth (dev only) |
| `kafka` | `9094` | KRaft single-broker, auto-creates topics, dual listener (internal/external) |
| `debezium` | `8083` | Kafka Connect with Debezium plugins, only comes up after PG+Kafka healthy |

**Postgres credentials (dev):** user `omnicore`, pass `omnicore`, db `users_db`.

### Bring up and register

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh   # idempotent
APP_PROFILE=dev go run ./bootstrap       # framework applies migrations at boot
```

The script registers the connector via the Kafka Connect REST API — POST if new, PUT /config if it already exists. It uses `$(dirname "$0")` to locate the `users-outbox-connector.json` next to it, so it works from any CWD.

---

## Debezium connector

`devops/debezium/users-outbox-connector.json` — Debezium config with the **Outbox Event Router**:

| Setting | Why |
|---|---|
| `connector.class: PostgresConnector` | CDC source from Postgres |
| `plugin.name: pgoutput` | Native plugin, no extra installation in PG |
| `publication.autocreate.mode: filtered` | Automatic publication creation only for tables in `include.list` |
| `table.include.list: public.outbox` | Watches only outbox (no domain table CDC leak) |
| `transforms.outbox.type: EventRouter` | Outbox pattern — transforms an outbox row into a Kafka msg |
| `route.by.field: aggregate_type` + `route.topic.replacement: ${routedByValue}.events` | `aggregate_type="users"` → topic `users.events` (matches the framework's `topicFromTable`) |
| `table.field.event.key: aggregate_id` | Key = aggregate_id → messages from the same entity go to the same partition (ordering preserved) |
| `table.fields.additional.placement: aggregate_type:header,event_type:header` | Puts aggregate_type and event_type in the Kafka headers (which the SyncEngine reads) |
| `key.converter: StringConverter` | Key comes out as a raw string, no JSON wrap |

**Compatibility with SyncEngine:** SyncEngine reads `aggregate_id` from the Kafka message key + `aggregate_type`/`event_type` from the headers. Exact match with what the Outbox Router produces.

---

## End-to-end flow of POST /users

```
1. POST /users { name, email, phone, addresses[...] }
2. Fiber middleware: AppContextMiddleware (UUID + Language from headers, default from bootstrap)
3. fwweb.HandleCommandWithBody → var req InsertUserRequest + c.Bind().Body(&req)
   3a. Malformed JSON → 400 with SchemaViolationNotification (semantic Schema, context "Schema")
   3b. Type mismatch (wrong field type) → 400 with SchemaViolationNotification (field from the JSON path, context "Schema")
   3c. (PUT only: FullBody marker) missing required field → 400 with RequiredFieldNotification (semantic Schema)
3.5. appCtx := fwweb.AppContext(c); appCtx.SetParent(c)
3.6. cmd := req.ToCommand(appCtx) — web→application boundary (1:1 assignment; appCtx exposed for future JWT overlays)
4. pipeline.Dispatch(pipe, ctx, cmd, InsertCommandHandler)
   └─ pipeline.Run wraps in defer/recover
      └─ Auto handler.Handle(ctx, *cmd)
         └─ user := cmd.ToEntity() — creates User + u.AddAddress(addr, nil) per address
         └─ domain.GetInsertable(user, nil)
            └─ BuildRules: validates root fields (children auto-iterated afterwards)
            └─ runAggregateValidations: Address.IsValid on each
            └─ checkAllNotifications → *DomainError if any
            └─ extractAggregateMeta(user) attaches *aggregateMeta
         └─ orch := persistence.NewOrchestrator(repo, auditor, ctx)
         └─ orch.Insert(insertable, nil, nil)
            └─ BaseRepository.Insert → pg.Insert
               └─ AggregateInfo() ok → insertAggregate
                  └─ BEGIN TX
                  └─ INSERT users RETURNING id
                  └─ for each Added Address: INSERT addresses (user_id injected)
                  └─ INSERT outbox (single row, payload = root+children snapshot)
                  └─ COMMIT
               └─ pgErr 23505 + known constraint → FieldErrorWithCause (Conflict 409)
            (inside Postgres.insertAggregate, IN-TX before COMMIT:)
            └─ ev := audit.BuildInsertEvent(ctx, insertable, id, cfg.AuditClaims)
            └─ IF cfg.Audit.Includes(database):
               └─ audit.InsertAuditEvent(ctx, tx, ev) ← atomic with data + outbox row
            └─ tx.Commit(ctx)
            (POST-COMMIT, best-effort echo:)
            └─ IF cfg.Audit.Includes(slog):
               └─ audit.EchoSlog(ctx, logger, ev)
         └─ return id, nil
   └─ Result.Success(id)
5. fwweb.RespondFromResult → 201 Created { success:true, data:id }

Async (eventual consistency, ~100-300ms):
6. Debezium reads outbox via WAL → publishes to users.events with:
     key=user_id, headers={aggregate_type, event_type}, value=payload
7. SyncEngine (goroutine in the same process) consumes users.events
   └─ extractEvent(msg): aggregate_id ← Key, type/eventType ← Headers
   └─ composer.Compose("users", user_id)
      └─ fetchRow users WHERE deleted_at IS NULL → root doc
      └─ applyEmbeds: fetchWhere addresses WHERE user_id=root.id AND deleted_at IS NULL
   └─ mongo.Upsert("users", user_id, doc)
8. GET /users/:id now returns the denormalized doc from Mongo
```

Validation or unique-constraint error: pipeline catch → translate → `Result.Failure(dtos)` → `RespondFromResult` consults each notification's `Semantic` → 422 / 409 / 404 according to the type. Wire violations emit 400 before Dispatch via the wrapper — pipeline still calls Translator manually on that path so that `message` comes translated.

---

## How to run

```bash
cd /Volumes/Lynx/Development/omnicore-stack/omnicore-example-users
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
APP_PROFILE=dev go run ./bootstrap  # framework applies migrations at boot
```

In another terminal, example POST:

```bash
curl -X POST http://localhost:8080/users \
  -H "Content-Type: application/json" \
  -H "Accept-Language: en-US" \
  -d '{
    "name": "Jane Doe",
    "email": "jane@example.com",
    "phone": "14155552671",
    "addresses": [{
      "label": "home",
      "street": "1 Infinite Loop",
      "number": "1",
      "neighborhood": "Mariani",
      "city": "Cupertino",
      "state": "CA",
      "zipCode": "95014",
      "country": "US"
    }]
  }'
```

GET after ~300ms (CDC delay):

```bash
curl http://localhost:8080/users/<returned-id>
```

Archive/Unarchive (aggregate-aware, cascade addresses; body optional):

```bash
curl -X PATCH http://localhost:8080/users/<id>/archive    # 200
curl -X PATCH http://localhost:8080/users/<id>/unarchive  # 200
```

Partial PATCH (no `archived` — state transition uses the dedicated endpoint):

```bash
curl -X PATCH http://localhost:8080/users/<id> \
  -H "Content-Type: application/json" \
  -d '{"name":"Jane Smith"}'
```

PUT (strict body — all exported fields mandatory; missing any → 422):

```bash
curl -X PUT http://localhost:8080/users/<id> \
  -H "Content-Type: application/json" \
  -d '{"name":"...","email":"...","phone":"...","addresses":[...]}'
```

---

## QA suites (`qa/`)

Six end-to-end scripts, all rely on `docker compose -f devops/docker-compose.yml up -d` + `./devops/debezium/register-connector.sh` as preconditions. `auth.sh`, `audit.sh`, `httpclient.sh`, and `authz.sh` additionally require the `keycloak` container to be ready (the realm import takes a few seconds on cold start).

### `qa/e2e.sh` — endpoint + notification coverage

Runs the service under `APP_PROFILE=dev` (auth disabled) and exercises every write/read route plus every custom notification declared in `domain/notifications.go`. Each case is bash-orchestrated via `show` — prints REQUEST/BODY/STATUS/RESPONSE and asserts. Per the critical rule at the top of this file, the expectations are an oracle and may not be edited to mask regressions.

### `qa/auth.sh` — JWT middleware coverage across the four validator modes

Boots the service four times under different `APP_PROFILE`s (`prd`, `prd-pem`, `prd-external`, `prd-external-cached`) against the test Keycloak realm — `omnicore-test` — that the `keycloak` container brings up automatically with the pinned RS256 keypair from `realm-export.json`. The script builds the server binary once, then for each profile: starts the binary, waits for `/health`, mints fresh tokens via `devops/keycloak/mint-token.sh`, exercises a fixed scenario set, and stops the binary cleanly (kills the PID directly — never `go run`, which leaks a child process). Scenario set per profile:

- public route accepts anonymous (publicRoutes bypass)
- protected route rejects missing bearer (`MissingAuthorizationNotification`)
- protected route rejects malformed JWT (`InvalidTokenNotification`)
- protected route rejects wrong-audience JWT (audience pin)
- protected route accepts valid alice JWT (subject = alice's UUID round-tripped from `AppContext.Identity`)

Plus mode-specific scenarios:

- `prd-external` — pre-revoke 200, RFC 7009 `/revoke`, post-revoke 401 (every request hits the IdP)
- `prd-external-cached` — pre-revoke 200 + cache populated, revoke, post-revoke within TTL still 200 (positive-only cache hit, by design — see [`omnicore/CLAUDE.md`](../omnicore/CLAUDE.md) "External validator"), sleep 31s, post-revoke after TTL 401 (cache expired, IdP says inactive)

Total: 25 cases. The script exits non-zero on any FAIL.

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
bash qa/auth.sh                  # ~5 minutes (4 profile boots + 31s cache-TTL wait)
```

### `qa/audit.sh` — audit pipeline coverage end-to-end (slog echo path)

Boots the service once under `APP_PROFILE=prd` (JWT mode + `auditClaims: [preferred_username, email]`) and exercises every write verb as alice — POST (Insert), PATCH partial (PartialUpdate), PUT (Update with addresses replaced), PATCH archive, PATCH unarchive, DELETE — capturing the v2 audit event the framework writes to stdout after each operation. For each case it asserts:

- **Actor capture from JWT** — `actor` equals alice's `sub`; `actorIssuer` matches the realm `iss`; `actorClaims` carries only the allow-listed claims (`preferred_username`, `email`) and never leaks `sub`/`iss`/`aud`/`exp`/`iat`/`azp`/`sid`/`jti`.
- **Flat top-level shape** — `threadId` is a UUID (= the AppContext request ID); `entityType=User`; `entityId` matches the persisted record; `verb` is the lowercase, SQL-grounded verb (`insert`/`update`/`archive`/`unarchive`/`delete` — PUT and PATCH share `update` because the SQL fingerprint is identical); `actionName` is the `Get*` constant chosen by the matching Auto handler (carries the PUT vs PATCH distinction when relevant); `kind` discriminates the body (`snapshot`/`delta`/`transition`); `dateTime` present; no nested `export` envelope.
- **Body block per kind** — Insert / Delete carry `snapshot` (state-after for Insert, pre-delete for Delete) and no `changes`; Update / PartialUpdate carry `changes` (delta-only — unchanged columns absent) and no `snapshot`; Archive / Unarchive carry neither block (kind=transition; the verb itself encodes the recovery).
- **Children block per verb (SQL-grounded ops)** — Insert shows `op=inserted` with `snapshot` (SQL: INSERT INTO addresses); root-only PATCH carries no children block (Constructor-status children skip — no SQL); PUT replace produces mixed `op=inserted` (new addresses) + `op=archived` (substituted addresses get `UPDATE deleted_at=NOW()` — the row stays in the DB, recoverable via unarchive); PUT on the address subresource (`/users/:id/addresses/:addressId`) produces `op=updated` with `changes` delta (SQL: UPDATE col=val); Archive emits `op=archived` + snapshot for every currently-active child (same SQL as PUT-replace REMOVED); **Unarchive emits `op=unarchived` for every archived child of the root** (symmetric cascade — including children archived by earlier Update operations, not only those touched by the matching Archive); Delete emits `op=deleted` for every loaded child (SQL: FK ON DELETE CASCADE).
- **Auth-rejected requests leave no audit trail** — a POST without bearer returns 401 and emits no audit line, guarding against a regression where the auditor would fall back to `actor=anonymous` on failed authentications and pollute forensics.

Total: 8 cases. The script orchestrates its own server lifecycle (build, start, kill_port-guarded boot, cleanup trap), reads the bearer from `devops/keycloak/mint-token.sh`, and grep-parses audit JSON lines out of the captured stdout log (`/tmp/omnicore-example-users-qa-audit.log`).

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
bash qa/audit.sh                 # ~10s (single profile boot, no IdP round-trips)
```

### `qa/httpclient.sh` — outbound HTTP showcase coverage

Exercises both the `/showcase/keycloak/*` endpoints (against the real Keycloak fixture) and the `/showcase/httpclient/*` endpoints (against the in-process `/echo/*` upstream) on a running instance of the service (`APP_PROFILE=dev`, server on `localhost:8080`, Keycloak on `localhost:8088`). Unlike `auth.sh` / `audit.sh`, it does **not** boot the server itself — start the service in another terminal first. Cases:

- **Health** — sanity 200 on `/health`.
- **Anonymous + cache (`keycloak-public`)** — `/showcase/keycloak/realm` returns 200 with `"issuer":"http://localhost:8088/realms/omnicore-test"`; two subsequent calls are warm (verifiable via slog `cacheStatus="hit"` in the server log).
- **OAuth2 admin (`keycloak-admin`)** — `/showcase/keycloak/admin/<uuid>` returns 502 carrying `status 403` (expected in the sandbox; the service account lacks `realm-management/view-users` — the test proves the OAuth2 provider acquired and forwarded the bearer). A second call with a different UUID is faster than the first by wall-clock, evidencing the per-provider token cache.
- **`credentials-exchange` multi-tenant (`keycloak-tenant`)** — missing `username`/`password` query params returns 400; correct credentials for alice (`alice123`) and bob (`bob123`) return 200 with `preferred_username` matching; wrong password returns 502 with `Invalid user credentials` (the upstream message preserved by the framework wrapper). Per-identity cache verified by interleaving alice → bob → alice and observing that alice's third call is warm despite bob's intermediate cold call.
- **Download streaming (`echo` / showcase)** — `/showcase/httpclient/download-stream/1024` returns 200 with `"bytes":1024`. The handler copies the framework's `StreamResponse.Body` through an `io.Reader` without buffering; the logging middleware records `responseBytes` from `Content-Length` only.
- **Upload streaming (`echo` / showcase)** — `POST /showcase/httpclient/upload-stream` with a 256-byte body returns 200 with `"received_bytes":256`. Proves the `http:"body,stream"` tag piped the bytes intact, retry was disabled (one-shot reader), and the logging middleware skipped request body capture.
- **Multipart upload (`echo` / showcase)** — `POST /showcase/httpclient/multipart` returns 200 with the upstream's parsed `passport.pdf` part. Proves the framework's `httpclient.Multipart` writer streamed through the `io.Pipe` and produced a parseable boundary.
- **Server-Sent Events (`echo` / showcase)** — `GET /showcase/httpclient/sse` returns 200 with `"count":3` and three events parsed by the EventSource pump. Verifies the WHATWG EventSource parser handles `event`, `id`, `data`, and `retry` fields.
- **HMAC signing (`echo-signed` / showcase)** — `POST /showcase/httpclient/signed` returns 200 with `x_signature`, `x_date`, `x_content_sha`, and `x_key_id` all populated. Four independent cases assert each header was injected end to end and the upstream observed it.
- **WithConfig per-call override (`echo` / showcase)** — `POST /showcase/httpclient/with-config-override` returns 200 with `"received_bytes":` set. The YAML declares the endpoint as `POST /echo/upload`; the handler re-specifies method + path through `CallConfig` to prove the runtime override surface is wired without breaking the dispatch.
- **InlineAuth Bearer (`echo-signed` / showcase)** — `POST /showcase/httpclient/inline-bearer?token=qa-test-bearer` returns 200 with `"authorization":"Bearer qa-test-bearer"`. Proves `CallConfig.InlineAuth.Bearer` propagates as the `Authorization` header without a YAML auth provider.

Wall-clock timing checks emit `WARN` instead of `FAIL` when inconclusive — local roundtrips at this scale can dip into the millisecond range where the timer's resolution is the bottleneck. The slog log is the authoritative ground truth.

Total: 21 cases.

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
APP_PROFILE=dev go run ./bootstrap   # in another terminal
bash qa/httpclient.sh                # ~3 seconds
```

### `qa/httpclient-redis.sh` — outbound HTTP cache backend swapped to Redis

Sibling of `qa/httpclient.sh` that swaps the framework's cache backend from in-process memory to Redis (`defaults.cache.store: redis`) via the dedicated `microservice.dev-redis-cache.yaml` variant. Loaded under `APP_PROFILE=dev` + `OMNICORE_CONFIG_PATH=./microservice.dev-redis-cache.yaml` — the YAML name advertises the variant while the profile stays `dev` so the framework's `auth.mode=disabled` guard keeps holding. Unlike `httpclient.sh`, this script **manages the service lifecycle itself** (build, kill_port, start, wait `/health`, cleanup trap) because case 5 needs to stop and restart the server, and case 6 needs to stop and restart the `redis` container — fighting an operator-managed server in another terminal would silently leak processes.

Six cases focused on what only Redis can demonstrate:

- **Case 1 — `redis-cli PING`.** `docker compose exec redis redis-cli PING` returns `PONG`. Proves the Redis container is reachable from inside the suite without depending on `redis-cli` on the host (every machine that has docker has the Redis CLI through this path).
- **Case 2 — Framework writes entries under the configured `keyPrefix`.** After `GET /showcase/keycloak/realm`, `redis-cli KEYS 'omnicore-example-users-httpcache:*'` returns at least one match and the sample key carries the `keycloak-public` service segment. Validates both that the adapter writes to Redis at all AND that the YAML `keyPrefix` is respected.
- **Case 3 — Entry decodes back as the framework's `CacheEntry` JSON shape.** `redis-cli GET <key>` pipes through `python3 -c "json.loads(...)"` and asserts the presence of `body`, `headers`, `status`, `contentType`, `contentLength`, `expiresAt`. Catches a regression where the on-wire envelope diverges from `omnicore/infra/httpclient/cache_redis.go::redisCacheEntryEnvelope`.
- **Case 4 — TTL is bounded by the endpoint's YAML configuration.** `redis-cli TTL <key>` returns an integer between 1 and 300 seconds (the endpoint declares `cache: { ttl: 5m }`). Proves the adapter does NOT silently apply the framework's 5-minute fallback when the YAML already set the value.
- **Case 5 — Cross-process cache persistence (THE Redis differentiator).** The script kills the server (`SERVER_PID` via SIGTERM, port 8080 freed); Redis still holds the entry (`DBSIZE = 1`). The script restarts the server (fresh process, fresh in-process memory) and hits `/showcase/keycloak/realm` again. The fresh process's slog line MUST carry `"cacheStatus":"hit"` — proving the cache entry survived the process restart, which an in-memory cache cannot do. This is the case that justifies pulling Redis into the dependency tree; the other five are sanity.
- **Case 6 — `failMode: open` graceful degradation.** With Redis up, `docker compose stop redis`. The next request to `/showcase/keycloak/realm` MUST still return `200` AND the server log MUST contain `httpclient.cache.redis.transport.error` — proving the framework's failOpen policy: cache backend dies → call proceeds to upstream as if cache were disabled + slog.Warn records the underlying problem so operators see Redis going down regardless of the HTTP response. The script then `docker compose start redis` and waits for `PING=PONG` before completing.

The cleanup trap (`trap cleanup EXIT INT TERM`) ensures that any early exit (case 6 mid-failure, Ctrl-C, kernel signal) still kills the spawned server and restarts the Redis container — the suite never leaves the dev environment in a worse state than it found.

Total: 6 cases.

```bash
docker compose -f devops/docker-compose.yml up -d        # brings up redis alongside the others
./devops/debezium/register-connector.sh
bash qa/httpclient-redis.sh                              # ~30s (self-managed lifecycle)
```

### `qa/openapi.sh` — OpenAPI document + Swagger UI

Validates the framework's OpenAPI surface end to end against a running service (`APP_PROFILE=dev`, server on `localhost:8080`). Like `httpclient.sh`, it does NOT boot the server itself — start it in another terminal first. Requires `jq` for JSON-path assertions. Cases:

- **Reachability** — `GET /openapi.json` returns 200 + `application/json`; body is valid JSON.
- **Top-level** — `openapi` is `3.1.0`; `info.title` matches `OmniCore Example Users`.
- **Canonical `/users/*` surface** — POST exists with the documented summary; PUT request body carries `required: true` (strict / `FullBody`); PATCH carries `required: false` (lenient); `/users/{id}/archive` + `/users/{id}/unarchive` registered with the cascade-summary; GET tags are `Users`; GET by id carries the auto-added 404 entry.
- **`/whoami`** — declared with summary; the 200 response references `#/components/schemas/WhoamiResponse` via `$ref`.
- **Manual showcase** — `POST /showcase/users-custom/` + `PUT /showcase/users-custom/{email}` declared with the manual-showcase tags.
- **`/echo/*` is Hidden** — `/echo/upload` and `/echo/sse` do NOT appear in `.paths` (proves `RawSpec.Hidden=true` enforcement).
- **`/health` auto-registered** — declared with the framework summary; carries no `security` entry (Public via the auto allowlist).
- **`ErrorEnvelope`** — registered exactly once in `components.schemas` and reused by every error response.
- **`/docs` HTML** — reachable; references `/openapi.json`; carries the service title.

Total: 22 cases. Fast (~1s); operationally cheap so safe to chain with `e2e.sh` in a "validate the spec after a route change" loop.

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
APP_PROFILE=dev go run ./bootstrap   # in another terminal
bash qa/openapi.sh                   # ~1 second
```

### `qa/authz.sh` — Authorization layer end-to-end (Layer 1 + Layer 2 + Public bypass)

Boots the service once under `APP_PROFILE=prd-authz` (JWT mode + `auth.authorization.enabled=true`) and validates that the declarative permission layer enforces correctly across the canonical and manual surfaces. Companion to `qa/auth.sh` (which validates authentication in isolation): this script validates that

1. The runtime gate (Layer 1) rejects requests whose JWT lacks the permission declared via `fwopenapi.RequirePermission` on each route.
2. The domain owner-check (Layer 2) rejects Archive when the principal's email claim does not match the persisted user's email — unless the principal carries `users:admin` (super-admin / `*:*` bypass).
3. Public routes (`RawSpec.Public:true` + `auth.publicRoutes`) bypass both the AuthMiddleware AND the permission gate, so `/health` + `/openapi.json` stay anonymous.

Test subjects (defined in `devops/keycloak/realm-export.json`):

| Subject | `permissions` claim | Email claim | Role in tests |
|---|---|---|---|
| `alice` | `[users:read, users:write, users:archive]` | `alice@omnicore.test` | regular operator; Layer-2 owner of users with her email |
| `bob` | `[*:*]` | `bob@omnicore.test` | super-admin; Layer-2 bypass via `HasPermission("users:admin")` |
| `noperm` | (no claim emitted) | `noperm@omnicore.test` | negative tests; every gated route returns 403 |

Scenarios — 17 cases, each asserting both HTTP status AND the `notificationKey` on the error envelope (so a 403 from the wrong cause does not silently pass):

- **Public bypass** — `GET /health`, `GET /openapi.json` 200 without bearer.
- **Layer 1 — missing bearer** — POST/GET `/users` 401 with `MissingAuthorizationNotification` (from `AuthMiddleware`, not the gate).
- **Layer 1 — bearer without claim** — POST/GET `/users` with `noperm` bearer 403 with `MissingPermissionNotification`.
- **Layer 1 — partial permissions** — alice has read+write+archive but NOT delete → DELETE 403; GET/POST 2xx.
- **Layer 2 — owner-check on Archive**:
  - alice archives a user she owns (email matches) → 200.
  - alice archives a stranger (email differs, not admin) → 403 `ArchiveNotAllowedNotification`.
  - bob (super-admin via `*:*`) archives the same stranger → 200 (Layer-2 bypass).
- **Manual showcase** — `GET /showcase/users-custom` carries the same matrix (noperm 403, alice 200).

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
bash qa/authz.sh                     # ~30s (single profile boot, no IdP round-trips beyond token mint)
```

The script orchestrates its own server lifecycle (build, start, kill_port-guarded boot, cleanup trap). The realm fixture exports a Protocol Mapper `permissions-from-user-attribute` on `omnicore-users-client` that reads the per-user `permissions` attribute and emits it as a multi-valued claim — so a fresh realm import is required if the Keycloak container was started before the mapper landed (`docker compose stop keycloak && docker compose rm -f keycloak && docker compose up -d keycloak`).

### `qa/schema_evolution.sh` — Mongo wipe-and-recover under the registry + advisory lock

Boots the service once under `APP_PROFILE=dev` (autoRun=true) and exercises the framework's Mongo schema-evolution path end to end. Sequence:

1. Reset state (truncate `users` + `outbox` + delete `omnicore_mongo_views` row + `db.users.deleteMany`) so the boot lands on a clean slate.
2. Start the service. Boot detects `DriftFreshInit` (no registry row + empty Mongo) → `InitRegistryOnly` writes the registry row at `status='done'`, `version=1` (UserView declares `Version(1)`).
3. Assert the registry row exists with the expected status + version.
4. POST 3 users via the canonical `/users` surface, wait `${CDC_WAIT_SEC:-3}` seconds for the Debezium → Kafka → SyncEngine pipeline to materialize them.
5. Assert `GET /users` returns 3 documents AND `db.users.countDocuments({})` returns 3.
6. Stop the server.
7. Run `db.users.drop()` via mongosh — simulates an operator wiping the read side (the §1 motivation case of the design doc).
8. Restart the server. Boot reads the registry (still present) + scans Mongo (empty) → detects `DriftMongoWiped` → `autoRun=true` authorizes the rebuild → `ExecuteRebuild` cycles the registry through `processing` → `done` while recomposing from PG.
9. Assert the slog log carries `view.rebuild.start` + `view.rebuild.end` events.
10. Assert Mongo is rebuilt: `GET /users` returns 3, `db.users.countDocuments({})` returns 3.
11. Assert the registry's `previous_*` fields capture the prior state (`previous_version`, `previous_applied_at IS NOT NULL`) and that `started_at IS NULL` (transition back to `done` cleared the in-flight columns).
12. Stop the server cleanly.

Total: 14 cases — covers FreshInit init → CDC propagation → wipe → MongoWiped rebuild → registry forensics. The script manages its own server lifecycle (build, start, kill_port-guarded boot, cleanup trap); pure docker-compose dependencies (no Keycloak required). Fast (~30s end to end including the CDC wait).

```bash
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh
bash qa/schema_evolution.sh          # ~30s
```

---

## Build

```
go build ./...
go vet ./...
```

Run from inside this folder or from `omnicore-stack/` (workspace-aware).
