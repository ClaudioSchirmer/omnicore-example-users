package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	appweb "github.com/ClaudioSchirmer/omnicore-example-users/web"

	"github.com/gofiber/fiber/v3"
)

// AuditFeature exposes the canonical audit-read endpoint for this
// service:
//
//	GET /audit/:aggregateId — timeline by aggregate (newest first)
//
// Mount-only feature — no domain repository, no view, no vendor
// adapter to cache. The audit reader operates against
// d.Postgres.Pool() + the framework's d.Translator, both already
// provided on Deps; there is nothing for the feature struct to wrap
// or hold. Same shape as AdminFeature — see the "Feature struct
// convention" section of this service's CLAUDE.md for why
// application-layer handlers are NEVER cached on the feature struct.
type AuditFeature struct{}

// NewAuditFeature returns the empty singleton. Deps reach the route
// at Mount time, the application handler is constructed inside the
// per-request closure (see findAuditByAggregateHandler in
// web/audit_routes.go).
func NewAuditFeature() *AuditFeature { return &AuditFeature{} }

// Mount delegates to web.MountAudit — owner of the Fiber + OpenAPI
// registration code, matching the project's MountXxx convention.
func (f *AuditFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountAudit(app, d)
}
