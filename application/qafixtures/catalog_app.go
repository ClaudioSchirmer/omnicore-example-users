//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// ─── Catalog command (normal insert) ─────────────────────────────────────────

// InsertCatalogCommand is a plain (non-shared-base) insert: ToEntity, unlike the
// AccountHolder shared-base upsert. FeaturedItemID wires the 1:1 embed.
type InsertCatalogCommand struct {
	pipeline.CommandBase
	Name           string
	FeaturedItemID *string
}

func (c *InsertCatalogCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Catalog, error) {
	return &qadomain.Catalog{Name: c.Name, FeaturedItemID: c.FeaturedItemID}, nil
}

func (c *InsertCatalogCommand) FromEntity(_ *configuration.AppContext, cat *qadomain.Catalog) (CatalogResult, error) {
	return CatalogResult{ID: *cat.GetID(), Name: cat.Name, FeaturedItemID: cat.FeaturedItemID}, nil
}

// CatalogResult is the application-layer projection of the insert; ID is the
// catalog id — the value Items reference as catalog_id.
type CatalogResult struct {
	ID             domain.ID
	Name           string
	FeaturedItemID *string
}

var _ pipeline.InsertCommand[*qadomain.Catalog, CatalogResult] = (*InsertCatalogCommand)(nil)

// ─── Catalog query (read the composed normal-view document) ──────────────────

// FindCatalogByIDQuery is the by-id read of the `qa_catalog_view` regular view:
// the flat catalog plus the two external embeds (FeaturedItem 1:1 + Items 1:N).
type FindCatalogByIDQuery struct {
	fwqueries.QueryBaseWithID
	IncludeArchived bool
}

func (q FindCatalogByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}

func (q FindCatalogByIDQuery) ContextName() string { return "Catalog" }

// FindCatalogsQuery is the paged LIST read of qa_catalog_view (a regular view):
// root + embed-segment filters, sort, ?fields= and pagination over the
// materialized document, proving the read-side vocabulary works on external
// embeds of a normal query.View exactly as it does on a shared-base view.
type FindCatalogsQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindCatalogsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
