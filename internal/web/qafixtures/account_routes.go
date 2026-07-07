//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountAccounts registers the shared-base embed showcase under /qa/accounts:
// create (upsert the identity + holder role via the SharedBase handler) and
// read the composed `qa_accounts_view` document by id (base fields flat + the
// AccountHolder role sub-document + the FeaturedItem 1:1 embed + the Items 1:N
// EmbedMany — both external, from the upstream_items projection).
func MountAccounts(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.AccountHolder],
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/accounts")
	viewName := view.Name()

	insertH, insertSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
		InsertAccountRequest{},
		InsertAccountResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*qadomain.AccountHolder, *appqa.InsertAccountHolderCommand, appqa.AccountHolderResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a shared-base account (identity + holder role)",
			Description: "UPSERT by `accountRef` (the base natural key → id = UUIDv5). Pass `featuredItemId` (an existing item id) to wire the 1:1 embed at insert time. The returned `id` is the base id — use it as items' `accountId` to populate the 1:N Items segment.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		FindAccountByIDRequest{},
		fwresponses.AutoFromDoc[FindAccountByIDResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindAccountByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a shared-base account by id (roles + external embeds)",
			Description: "Reads the `qa_accounts_view` SharedBaseView document: base fields flat, the `accountHolder` role sub-document, the 1:1 `featuredItem` embed (null until the referenced upstream_items doc is materialized/rippled), and the 1:N `items` array (upstream_items whose account_id equals this account). Proves external Embed AND EmbedMany compose on a shared-base root.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		FindAccountsRequest{},
		fwresponses.AutoFromDoc[FindAccountsListResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindAccountsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List shared-base accounts (paged; filter/sort/fields into embeds)",
			Description: "Paged read of `qa_accounts_view`. Root filters (`accountRef`, `displayName`), the role segment (`accountHolder.holderName`) AND the embed segments (`featuredItem.label`, `items.label`) all select ROWS over the materialized document; `?sort=`, `?fields=` (incl. into segments), `?limit`/`?after`/`?before`, `?onlyTotal` apply as on any view.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	csvH, csvSpec := fwweb.HandleQueryAsCSVSpec(d.Pipeline,
		FindAccountsRequest{}, view, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindAccountsQuery]{Reader: d.ViewReader, View: viewName},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/accounts.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary: "Export accounts as CSV (root + embed segment branches)",
			Tags:    []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	xlsxH, xlsxSpec := fwweb.HandleQueryAsXLSXSpec(d.Pipeline,
		FindAccountsRequest{}, view, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindAccountsQuery]{Reader: d.ViewReader, View: viewName},
		export.WithSheetName("Accounts"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/accounts.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary: "Export accounts as Excel (root + embed segment branches)",
			Tags:    []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// ─── Create DTOs ─────────────────────────────────────────────────────────────

// InsertAccountRequest is the JSON body of POST /qa/accounts.
type InsertAccountRequest struct {
	AccountRef     string  `json:"accountRef"                example:"acct-001"`
	DisplayName    string  `json:"displayName"               example:"Primary Account"`
	FeaturedItemID *string `json:"featuredItemId,omitempty"  example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	HolderName     string  `json:"holderName"                example:"Ada Lovelace"`
}

func (r InsertAccountRequest) ToCommand() *appqa.InsertAccountHolderCommand {
	return &appqa.InsertAccountHolderCommand{
		AccountRef:     r.AccountRef,
		DisplayName:    r.DisplayName,
		FeaturedItemID: r.FeaturedItemID,
		HolderName:     r.HolderName,
	}
}

// InsertAccountResponse is the wire shape of a successful account upsert.
type InsertAccountResponse struct {
	ID             string  `json:"id"`
	AccountRef     string  `json:"accountRef"`
	DisplayName    string  `json:"displayName"`
	FeaturedItemID *string `json:"featuredItemId,omitempty"`
	HolderName     string  `json:"holderName"`
}

func (InsertAccountResponse) FromResult(r appqa.AccountHolderResult) InsertAccountResponse {
	return InsertAccountResponse{
		ID:             r.ID.String(),
		AccountRef:     r.AccountRef,
		DisplayName:    r.DisplayName,
		FeaturedItemID: r.FeaturedItemID,
		HolderName:     r.HolderName,
	}
}

// ─── Read DTOs ───────────────────────────────────────────────────────────────

// FindAccountByIDRequest is the wire allowlist of GET /qa/accounts/:id.
type FindAccountByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindAccountByIDRequest) ToQuery() *appqa.FindAccountByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &appqa.FindAccountByIDQuery{IncludeArchived: arch}
}

// FindAccountByIDResponse is the composed shared-base projection. AutoFromDoc
// keys every nested segment by its Go field name: `AccountHolder` is the role
// segment (the role's Go type name), `FeaturedItem`/`Items` are the embed .As
// names. Segment fields carry the upstream_items external schema's Go names
// (ID/Label/AccountID).
type FindAccountByIDResponse struct {
	ID             string               `json:"id"`
	AccountRef     string               `json:"accountRef"`
	DisplayName    string               `json:"displayName"`
	FeaturedItemID *string              `json:"featuredItemId,omitempty"`
	AccountHolder  *AccountHolderOutput `json:"accountHolder,omitempty"`
	FeaturedItem   *ItemSegmentOutput   `json:"featuredItem,omitempty"`
	Items          []ItemSegmentOutput  `json:"items,omitempty"`
}

// AccountHolderOutput is the role sub-document (role-private fields only; the
// base fields live flat at the root). Pointer field so `?fields=` prunes it.
type AccountHolderOutput struct {
	HolderName *string `json:"holderName,omitempty"`
}

// ItemSegmentOutput is one embedded upstream_items document, shared by the 1:1
// FeaturedItem segment and each entry of the 1:N Items array — on BOTH the
// shared-base AccountView and the normal CatalogView. Field names match the
// upstream_items external schema Go names (ID/Label/AccountID/CatalogID); every
// field is a pointer so `?fields=` sparse projection prunes into the segment.
type ItemSegmentOutput struct {
	ID        *string `json:"id,omitempty"`
	Label     *string `json:"label,omitempty"`
	AccountID *string `json:"accountId,omitempty"`
	CatalogID *string `json:"catalogId,omitempty"`
}

// ─── List DTOs (filter / sort / fields / pagination — incl. into embeds) ─────

// ItemSegmentFilter is the filter group for an embed segment (FeaturedItem /
// Items). Its Go field name on the request matches the segment, so a wire
// `featuredItem.label=` / `items.label=` parses to the segment-prefixed criteria
// path the reader resolves into the materialized doc's nested field — the SAME
// mechanism a role-segment filter uses. On a materialized view this selects
// ROWS (docs whose nested segment matches), not shapes the segment.
type ItemSegmentFilter struct {
	Label *string `query:"label" filter:"eq,contains"`
}

// AccountHolderFilter is the filter group for the AccountHolder role segment.
type AccountHolderFilter struct {
	HolderName *string `query:"holderName" filter:"eq,icontains"`
}

// FindAccountsRequest is the wire allowlist of GET /qa/accounts (+ .csv/.xlsx).
type FindAccountsRequest struct {
	AccountRef  *string `query:"accountRef"  filter:"eq,startswith"`
	DisplayName *string `query:"displayName" filter:"eq,icontains"`

	AccountHolder AccountHolderFilter `query:"accountHolder"`
	FeaturedItem  ItemSegmentFilter   `query:"featuredItem"`
	Items         ItemSegmentFilter   `query:"items"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	IncludeArchived *bool   `query:"includeArchived"`
}

func (r FindAccountsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindAccountsQuery {
	return &appqa.FindAccountsQuery{Criteria: criteria}
}

// FindAccountsListResponse is the per-item wire projection of the paged list —
// every field a pointer / omitempty slice so `?fields=` prunes cleanly,
// including into the embed segments.
type FindAccountsListResponse struct {
	ID             *string              `json:"id,omitempty"`
	AccountRef     *string              `json:"accountRef,omitempty"`
	DisplayName    *string              `json:"displayName,omitempty"`
	FeaturedItemID *string              `json:"featuredItemId,omitempty"`
	AccountHolder  *AccountHolderOutput `json:"accountHolder,omitempty"`
	FeaturedItem   *ItemSegmentOutput   `json:"featuredItem,omitempty"`
	Items          []ItemSegmentOutput  `json:"items,omitempty"`
}
