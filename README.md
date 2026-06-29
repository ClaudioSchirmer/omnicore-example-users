# omnicore-example-users

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Reference microservice that consumes the [`omnicore`](https://github.com/ClaudioSchirmer/omnicore) framework.

This service is two things at once:

1. **Canonical example** — a complete, runnable microservice showing every framework feature in production-shaped wire-up. Read its source when you want to know "how do I do X with omnicore?".
2. **Test bench** — exercises the framework's public surface and surfaces gaps. New framework features ship with new cases here; the QA scripts under [`qa/`](qa/) (`e2e.sh`, `auth.sh`, `audit.sh`, `httpclient.sh`) prove the contract end-to-end against a real relational backend + Mongo + Kafka + Debezium + Keycloak.

The persistence layer is **database-agnostic**: the relational backend is selected by `database.dialect` in the YAML, so the service code, repositories, and Go tests name no specific database.

## Domain

A users CRUD service with `Address` as an aggregate child of `User`. The domain is deliberately small so the architecture is easy to follow; the interesting code is in how the framework's primitives connect — `bootstrap.Run`, `UsersFeature`, `Auto Command Handlers`, `Auto Query Handlers`, `AuthMiddleware`, `audit`, `httpclient`.

## Run it locally

```bash
# 1. Bring up the relational backend + Mongo + Kafka + Debezium (+ Keycloak for auth profiles)
docker compose -f devops/docker-compose.yml up -d
./devops/debezium/register-connector.sh

# 2. Start the service in dev profile (auth disabled, migrations auto-run)
APP_PROFILE=dev go run ./bootstrap

# 3. Open the Swagger UI
open http://localhost:8080/docs
```

Other profiles ship as `microservice.prd.yaml`, `microservice.prd-pem.yaml`, `microservice.prd-external.yaml`, `microservice.prd-external-cached.yaml`, `microservice.prd-authz.yaml` — each exercising a different auth / authorization configuration.

## Layout

- `domain/` — `User` (AggregateRoot), `Address` (AggregateValueObject), custom notifications.
- `application/commands/` — Insert/Update/Patch/Archive/Unarchive/Delete commands per aggregate.
- `application/handlers/` — manual handlers (e.g. Keycloak-aware showcase); the Auto handlers from omnicore cover the trivial CRUD.
- `application/translations/` — service-specific notification messages (PT-BR, ENG, ESP, FRA, DEU, ITA, NLD).
- `infra/` — `UserRepository`, `ViewDefinition`, optional outbound HTTP services. Backend-agnostic: repositories take the neutral relational engine (`core.RelationalEngine`), never a concrete driver.
- `web/` — Fiber routes via `MountUsers`.
- `bootstrap/` — `package main` (entry point), Wire, UsersFeature.
- `migrations/` — service schema (versions `0002+`; the framework owns version `0001`).
- `devops/` — local docker-compose stack, Debezium connector boilerplate, Keycloak realm fixture.
- `qa/` — bash + curl + python end-to-end suites.

See [`CLAUDE.md`](CLAUDE.md) for maintainer-level details.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
