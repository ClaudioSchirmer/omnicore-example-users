//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ─── AccountHolder command (shared-base upsert) ──────────────────────────────

// InsertAccountHolderCommand creates the shared-identity + its holder role. It
// is the SharedBase upsert contract (ApplyTo, not ToEntity): the framework
// loads the existing identity by natural key (AccountRef) first, then applies
// this on top. FeaturedItemID is the 1:1 embed FK — set it to an existing
// upstream_items _id to wire the "featuredItem" segment at insert time.
type InsertAccountHolderCommand struct {
	pipeline.CommandWithBodyBase
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

// UpdateAccountCommand is the PATCH driving the ENTITY-side 1:1 embed lever:
// repointing FeaturedItemID re-references the featured item WITHOUT any item
// event — the projected segment must converge through the write-side repair
// (or the newly-referenced item's own ripple), never through luck. DisplayName
// exercises a base-field update through the role; HolderName a role-private
// one. Non-nil fields apply; nil is left unchanged (partial semantics — an
// explicit null clear is not expressible here; the null outcome is covered by
// the source-item delete path).
type UpdateAccountCommand struct {
	pipeline.CommandWithBodyIDBase
	DisplayName    *string
	FeaturedItemID *string
	HolderName     *string
}

func (c *UpdateAccountCommand) ApplyPartiallyTo(_ *configuration.AppContext, a *qadomain.AccountHolder) error {
	if c.DisplayName != nil {
		a.DisplayName = *c.DisplayName
	}
	if c.FeaturedItemID != nil {
		a.FeaturedItemID = c.FeaturedItemID
	}
	if c.HolderName != nil {
		a.HolderName = *c.HolderName
	}
	return nil
}

func (c *UpdateAccountCommand) FromEntity(_ *configuration.AppContext, a *qadomain.AccountHolder) (AccountHolderResult, error) {
	return AccountHolderResult{
		ID:             *a.GetID(),
		AccountRef:     a.AccountRef,
		DisplayName:    a.DisplayName,
		FeaturedItemID: a.FeaturedItemID,
		HolderName:     a.HolderName,
	}, nil
}

// ─── AccountHolder query (read the composed shared-base document) ─────────────

// FindAccountByIDQuery is the by-id read of the `qa_accounts_view`
// SharedBaseView: the base fields flat, the AccountHolder role sub-document,
// and the two external embeds (FeaturedItem 1:1 + Items 1:N).
type FindAccountByIDQuery struct {
	fwqueries.QueryByIDBase
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
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindAccountsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
