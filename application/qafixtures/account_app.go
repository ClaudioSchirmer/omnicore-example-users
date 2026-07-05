//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// ─── AccountHolder command (shared-base upsert) ──────────────────────────────

// InsertAccountHolderCommand creates the shared-identity + its holder role. It
// is the SharedBase upsert contract (ApplyTo, not ToEntity): the framework
// loads the existing identity by natural key (AccountRef) first, then applies
// this on top. FeaturedItemID is the 1:1 embed FK — set it to an existing
// upstream_items _id to wire the "featuredItem" segment at insert time.
type InsertAccountHolderCommand struct {
	pipeline.CommandBase
	AccountRef     string
	DisplayName    string
	FeaturedItemID *string
	HolderName     string
}

func (c *InsertAccountHolderCommand) ApplyTo(_ *configuration.AppContext, a *qadomain.AccountHolder) error {
	a.AccountRef = c.AccountRef
	a.DisplayName = c.DisplayName
	a.FeaturedItemID = c.FeaturedItemID
	a.HolderName = c.HolderName
	return nil
}

func (c *InsertAccountHolderCommand) FromEntity(_ *configuration.AppContext, a *qadomain.AccountHolder) (AccountHolderResult, error) {
	return AccountHolderResult{
		ID:             *a.GetID(),
		AccountRef:     a.AccountRef,
		DisplayName:    a.DisplayName,
		FeaturedItemID: a.FeaturedItemID,
		HolderName:     a.HolderName,
	}, nil
}

// AccountHolderResult is the application-layer projection of the upsert; ID is
// the base id (UUIDv5 of AccountRef) — the value Items reference as account_id.
type AccountHolderResult struct {
	ID             domain.ID
	AccountRef     string
	DisplayName    string
	FeaturedItemID *string
	HolderName     string
}

var _ pipeline.SharedBaseInsertCommand[*qadomain.AccountHolder, AccountHolderResult] = (*InsertAccountHolderCommand)(nil)

// ─── AccountHolder query (read the composed shared-base document) ─────────────

// FindAccountByIDQuery is the by-id read of the `qa_accounts_view`
// SharedBaseView: the base fields flat, the AccountHolder role sub-document,
// and the two external embeds (FeaturedItem 1:1 + Items 1:N).
type FindAccountByIDQuery struct {
	fwqueries.QueryBaseWithID
	IncludeArchived bool
}

func (q FindAccountByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}

func (q FindAccountByIDQuery) ContextName() string { return "Account" }

// FindAccountsQuery is the paged LIST read of qa_accounts_view. Root filters,
// segment filters (into the AccountHolder role AND the FeaturedItem/Items
// embeds), sort, ?fields= and pagination all resolve over the ONE materialized
// document — a segment filter selects ROWS (the doc whose nested segment
// matches), unlike a ComposedView where it shapes the segment at read time.
type FindAccountsQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindAccountsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
