//go:build qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// ShowcaseFeature mounts the framework-exercise routes that are NOT part of the
// business surface — the "abobrinhas" that only exist to drive framework
// subsystems end to end from the QA suites:
//
//	MountWhoami        → GET /whoami (auth identity demo)
//	MountShowcase      → /showcase/keycloak/* + /showcase/httpclient/*
//	MountEcho          → /echo/* in-process upstream for the httpclient demos
//	MountCacheShowcase → /showcase/cache/* over Deps.Cache / Deps.SharedCache
//
// It is compiled only under //go:build qa, so the canonical binary never
// carries these routes. The User aggregate's manual showcase
// (/showcase/users-custom/*) is BUSINESS and lives in the canonical
// UserCustomFeature, not here.
//
// The feature contributes no view to the SyncEngine — it implements
// bootstrap.Feature only. KeycloakService and EchoService are constructed over
// the shared HttpClient registry the framework exposes on bootstrap.Deps.
type ShowcaseFeature struct {
	kc        *infraqa.KeycloakService
	echo      *infraqa.EchoService
	grpcUsers *infraqa.UsersGRPCService
	grpcQA    *infraqa.QAGRPCService
}

// NewShowcaseFeature builds the outbound adapters over the shared HttpClient.
func NewShowcaseFeature(d bootstrap.Deps) *ShowcaseFeature {
	return &ShowcaseFeature{
		kc:   infraqa.NewKeycloakService(d.HttpClient),
		echo: infraqa.NewEchoService(d.HttpClient),
		// The grpcclient adapter resolves at composition time; nil when the
		// grpcClient yaml block is absent — the showcase route answers 503.
		grpcUsers: newUsersGRPCServiceOrNil(d),
		grpcQA:    newQAGRPCServiceOrNil(d),
	}
}

func newQAGRPCServiceOrNil(d bootstrap.Deps) *infraqa.QAGRPCService {
	svc, err := infraqa.NewQAGRPCService(d.GRPCClient)
	if err != nil {
		return nil
	}
	return svc
}

func newUsersGRPCServiceOrNil(d bootstrap.Deps) *infraqa.UsersGRPCService {
	svc, err := infraqa.NewUsersGRPCService(d.GRPCClient)
	if err != nil {
		return nil
	}
	return svc
}

// Mount satisfies bootstrap.Feature — registers the framework-exercise routes.
// /echo/* is the upstream of /showcase/httpclient/* so MountEcho lands in the
// same Fiber app.
func (f *ShowcaseFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountWhoami(app, d)
	webqa.MountEcho(app, d)
	webqa.MountShowcase(app, f.kc, f.echo, d)
	webqa.MountCacheShowcase(app, d)
	webqa.MountGrpcClientShowcase(app, f.grpcUsers, f.grpcQA, d)
	webqa.MountGrpcClientResilience(app, f.grpcQA, d)
}
