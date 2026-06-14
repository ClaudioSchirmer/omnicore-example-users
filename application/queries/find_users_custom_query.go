package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUsersCustomQuery is the paged-list transport for the manual showcase
// under GET /showcase/users-custom. The route parses the query string via
// fwweb.ParseCriteria (same allowlist semantics as the canonical wrapper)
// and populates Criteria; ToCriteria(ctx) is the seam where AppContext-
// derived overlays (tenant id, owner id) would layer on top before the
// handler forwards to ViewReader.ReadPage.
//
// Why no Request DTO with filter tags shared with the canonical:
// FindUsersByParamsRequest declares the allowlist via struct tags consumed
// by HandleQueryWithParams reflection. The manual chain skips that
// wrapper but still feeds the same ParseCriteria — see web/user_custom_routes.go.
type FindUsersCustomQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindUsersCustomQuery) ToCriteria(_ *configuration.AppContext) fwqueries.ReadCriteria {
	return q.Criteria
}
