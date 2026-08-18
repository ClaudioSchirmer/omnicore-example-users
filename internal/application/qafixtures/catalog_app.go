//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ─── Catalog command (normal insert) ─────────────────────────────────────────

// InsertCatalogCommand is a plain (non-shared-base) insert: ToEntity, unlike the
// AccountHolder shared-base upsert. FeaturedItemID wires the 1:1 embed.
type InsertCatalogCommand struct {
	pipeline.CommandWithBodyBase
	Name           string
	FeaturedItemID *string
	Lines          []CatalogLineInput
}

// CatalogLineInput is the application-layer shape of one native child line:
// ItemID is the ParentID the view enriches via EmbedInChild; Note is the line's own
// field.
type CatalogLineInput struct {
	ItemID *string
	Note   string
}

func (c *InsertCatalogCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Catalog, error) {
	cat := &qadomain.Catalog{Name: c.Name, FeaturedItemID: c.FeaturedItemID}
	for _, l := range c.Lines {
		cat.AddLine(qadomain.CatalogLine{ItemID: l.ItemID, Note: l.Note})
	}
	return cat, nil
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
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindCatalogByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindCatalogByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindCatalogByIDResult) (FindCatalogByIDResult, error) {
	return r, nil
}

func (q FindCatalogByIDQuery) ContextName() string { return "Catalog" }

// FindCatalogByIDResult is the by-id Result of the composed normal-view
// document: the flat catalog plus the 1:1 FeaturedItem embed, the 1:N Items
// array and the native child lines (each carrying the materialized `Item`
// EmbedInChild sub-document and, on the qa_catalog_full ComposedView, the
// read-time `LiveItem` twin). The by-id endpoint declares no `?fields=`, so
// the root leaves are plain values.
type FindCatalogByIDResult struct {
	ID             string
	Name           string
	FeaturedItemID *string
	FeaturedItem   *ItemSegmentResult
	Items          []ItemSegmentResult
	CatalogLines   []CatalogLineResult
}

// FindCatalogsResult is the paged listing's Result — pointers/slices
// throughout because the endpoint opts into `?fields=`, including into the
// embed segments.
type FindCatalogsResult struct {
	ID             *string
	Name           *string
	FeaturedItemID *string
	FeaturedItem   *ItemSegmentResult
	Items          []ItemSegmentResult
	CatalogLines   []CatalogLineResult
}

// CatalogLineResult is one enriched native child line: its own identity
// (ID/ParentID) and fields, the materialized `Item` EmbedInChild segment and
// the read-time `LiveItem` LinkInChild twin.
type CatalogLineResult struct {
	ID       *string
	ParentID *string
	ItemID   *string
	Note     *string
	Item     *ItemSegmentResult
	LiveItem *ItemSegmentResult
}

// FindCatalogsQuery is the paged LIST read of qa_catalog_view (a regular view):
// root + embed-segment filters, sort, ?fields= and pagination over the
// materialized document, proving the read-side vocabulary works on external
// embeds of a normal query.View exactly as it does on a shared-base view.
type FindCatalogsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindCatalogsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindCatalogsQuery) FromQueryResult(_ *configuration.AppContext, r FindCatalogsResult) (FindCatalogsResult, error) {
	return r, nil
}
