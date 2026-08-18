package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUsersCustomQuery is the paged-list transport for the manual showcase
// under GET /showcase/users-custom. The route parses the query string via
// a typed fwweb.QueryParser (same allowlist semantics as the canonical wrapper)
// and populates Criteria; ToCriteria(ctx) is the seam where AppContext-
// derived overlays (tenant id, owner id) would layer on top before the
// handler forwards to ViewReader.ReadPage.
//
// Why no Request DTO with filter tags shared with the canonical:
// FindUsersByParamsRequest declares the allowlist via struct tags consumed
// by QueryWithParams reflection. The manual chain skips that
// wrapper but still feeds the same parser — see web/user_custom_routes.go.
type FindUsersCustomQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindUsersCustomQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the mandatory read-side projection hook — the manual chain
// carries the SAME seat the canonical wrapper does, so the two surfaces stay
// feature-equivalent (framework rule: manual is an escape hatch for wiring
// control, never a poorer tier).
func (q FindUsersCustomQuery) FromQueryResult(_ *configuration.AppContext, r FindUsersCustomResult) (FindUsersCustomResult, error) {
	return r, nil
}

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindUsersCustomResult is the reduced application-layer Result of the manual
// showcase listing — id + name + email. Sparse pointers: the Request DTO opts
// into `?fields=`.
type FindUsersCustomResult struct {
	ID    *string
	Name  *string
	Email *string
}
