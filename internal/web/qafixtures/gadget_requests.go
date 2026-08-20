//go:build qa

// Package qafixtures (web layer) owns the wire surface of the QA-only Gadget
// aggregate: request/response DTOs (JSON + filter tags) and the route mount.
// Gated behind the `qa` build tag.
package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// ─── Insert (shared by the Auto and the manual custom route) ────────────────

// InsertGadgetRequest is the JSON body of POST /qa/gadgets and
// POST /qa/gadgets/custom. Both routes map it to the same *InsertGadgetCommand
// — the Auto route lets the command's AfterBegin/BeforeCommit fire; the manual
// route ignores those methods and installs equivalent closures.
type InsertGadgetRequest struct {
	Code     string `json:"code"     example:"WIDGET-001"`
	Name     string `json:"name"     example:"Widget One"`
	Category string `json:"category" example:"tools"`
	Status   string `json:"status"   example:"active"`
}

func (r InsertGadgetRequest) ToCommand() *appqa.InsertGadgetCommand {
	return &appqa.InsertGadgetCommand{
		Code:     r.Code,
		Name:     r.Name,
		Category: r.Category,
		Status:   r.Status,
	}
}

// InsertGadgetResponse is the wire shape of a successful insert.
type InsertGadgetResponse struct {
	ID       domain.ID `json:"id"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code     string    `json:"code"     example:"WIDGET-001"`
	Name     string    `json:"name"     example:"Widget One"`
	Category string    `json:"category" example:"tools"`
	Status   string    `json:"status"   example:"active"`
}

func (InsertGadgetResponse) FromResult(r appqa.InsertGadgetResult) InsertGadgetResponse {
	return InsertGadgetResponse{
		ID:       r.ID,
		Code:     r.Code,
		Name:     r.Name,
		Category: r.Category,
		Status:   r.Status,
	}
}

// ─── Receiver (self-consumed gadgetCreated integration event) ───────────────

// GadgetCreatedReceivedRequest is the wire DTO the integration Registry
// unmarshals each consumed `gadgetCreated` message into. Its json keys mirror
// GadgetCreatedEvent (the producer payload) so self-consumption round-trips.
// ToCommand maps it to the idempotent sink command — the same ToCommand
// contract HTTP request DTOs use, which is how the framework's receiver
// reflection bridges a Kafka message to a pipeline.CommandHandler.
type GadgetCreatedReceivedRequest struct {
	GadgetID string `json:"gadgetId"`
	Code     string `json:"code"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Status   string `json:"status"`
}

func (r GadgetCreatedReceivedRequest) ToCommand() *appqa.RecordGadgetEventCommand {
	return &appqa.RecordGadgetEventCommand{
		GadgetID: r.GadgetID,
		Code:     r.Code,
		Name:     r.Name,
		Category: r.Category,
		Status:   r.Status,
	}
}

// ─── List (the full filter-operator vocabulary) ─────────────────────────────

// FindGadgetsRequest declares the wire allowlist for GET /qa/gadgets. The four
// business fields spread all 16 filter operators across their leaves, plus the
// reserved pagination/control keys:
//
//	Code     → eq,in,nin,gte,lte,gt,lt,startswith
//	Name     → eq,ne,startswith,contains,icontains,istartswith,ine
//	Category → eq,in,iin,inin,ieq
//	Status   → eq,ne,ieq,ine
type FindGadgetsRequest struct {
	Code     *string `query:"code"     filter:"eq,in,nin,gte,lte,gt,lt,startswith" sort:"asc,desc"`
	Name     *string `query:"name"     filter:"eq,ne,startswith,contains,icontains,istartswith,ine" sort:"asc,desc"`
	Category *string `query:"category" filter:"eq,in,iin,inin,ieq" sort:"asc,desc"`
	Status   *string `query:"status"   filter:"eq,ne,ieq,ine" sort:"asc,desc"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	OrderBy         *string `query:"orderBy"`
}

func (r FindGadgetsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetsQuery {
	return &appqa.FindGadgetsQuery{Criteria: criteria}
}

// FindGadgetsBareRequest declares ONLY filter leaves — no reserved control
// keys. It exists to prove the canonical control gateway end to end on every
// surface: the DTO is the single source of truth for what an endpoint
// exposes, so every reserved control arriving on this endpoint's wire must
// reject (REST 400 / GraphQL unknown argument via the SDL cut / gRPC
// INVALID_ARGUMENT) while plain filters keep working.
type FindGadgetsBareRequest struct {
	Code     *string `query:"code"     filter:"eq,startswith"`
	Name     *string `query:"name"     filter:"eq,contains"`
	Category *string `query:"category" filter:"eq"`
	Status   *string `query:"status"   filter:"eq"`
}

func (r FindGadgetsBareRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetsQuery {
	return &appqa.FindGadgetsQuery{Criteria: criteria}
}

// FindGadgetsResponse is the per-item wire projection of the list read. Every
// field is *T + ,omitempty so `?fields=` sparse rendering elides absent leaves.
type FindGadgetsResponse struct {
	fwresponses.Auto
	ID       *string `json:"id,omitempty"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code     *string `json:"code,omitempty"     example:"WIDGET-001"`
	Name     *string `json:"name,omitempty"     example:"Widget One"`
	Category *string `json:"category,omitempty" example:"tools"`
	Status   *string `json:"status,omitempty"   example:"active"`
}

// FromResult is the wire mapping seat — the read-side twin of the command
// Responses' FromResult. fwresponses.AutoFromResult is the generic name-based mapper
// (Result field → same-named Response field, emitted under its json tag).
func (FindGadgetsResponse) FromResult(r appqa.FindGadgetsResult) FindGadgetsResponse {
	return fwresponses.AutoFromResult[FindGadgetsResponse](r)
}

// FindGadgetsComputedResponse is the COMPUTED-field showcase: `label` carries
// no column — the Query's FromQueryResult derives it — so the field declares
// the Result fields that feed it via `computed:"Code,Name"`.
//
// Note what is NOT here: `Name`. A computed source need not appear on the
// Response; it is read so the derivation has data and then never reaches the
// wire. `?fields=label` therefore reads code+name from the store and answers
// with label alone.
//
// The two refusals this shape locks in: `?orderBy=label` is 400 — ordering
// speaks the Request DTO's `sort:` vocabulary, and a computed field is
// never in it because it backs no column to order by — and a `filter:` tag
// over label would be a boot panic, for the same reason.
type FindGadgetsComputedResponse struct {
	fwresponses.Auto
	ID    *string `json:"id,omitempty"    example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code  *string `json:"code,omitempty"  example:"WIDGET-001"`
	Label *string `json:"label,omitempty" exportLabelKey:"GadgetLabelField" computed:"Code,Name" example:"WIDGET-001 · Widget One"`
}

func (FindGadgetsComputedResponse) FromResult(r appqa.FindGadgetsResult) FindGadgetsComputedResponse {
	return fwresponses.AutoFromResult[FindGadgetsComputedResponse](r)
}

// ─── By id ───────────────────────────────────────────────────────────────────

// FindGadgetByIDRequest is the wire allowlist for GET /qa/gadgets/:id — only
// ?includeArchived is recognized.
type FindGadgetByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

// FindGadgetBareByIDRequest is the by-id half of the reserved-gate proof: it
// declares NOTHING, so even `?includeArchived` — the one reserved control the
// by-id surface speaks — rejects as the canonical NotDeclared 400 instead of
// being silently ignored.
type FindGadgetBareByIDRequest struct{}

func (r FindGadgetBareByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetByIDQuery {
	return &appqa.FindGadgetByIDQuery{Criteria: criteria}
}

func (r FindGadgetByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetByIDQuery {
	return &appqa.FindGadgetByIDQuery{Criteria: criteria}
}

// FindGadgetByIDResponse is the wire projection of the by-id read.
type FindGadgetByIDResponse struct {
	fwresponses.Auto
	ID       string `json:"id"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code     string `json:"code"     example:"WIDGET-001"`
	Name     string `json:"name"     example:"Widget One"`
	Category string `json:"category" example:"tools"`
	Status   string `json:"status"   example:"active"`
}

func (FindGadgetByIDResponse) FromResult(r appqa.FindGadgetByIDResult) FindGadgetByIDResponse {
	return fwresponses.AutoFromResult[FindGadgetByIDResponse](r)
}

// ─── Embedded by id (root gadget + one-to-one upstream mirror) ───────────────

// FindGadgetEmbeddedByIDResponse is the wire projection of the embedded read
// (GET /qa/gadgets-embedded/:id) against the `gadgets_embedded` view. It is the
// flat gadget PLUS the one-to-one `upstreamMirror` embed the composer fills from
// the `upstream_gadgets` projection. UpstreamMirror is a pointer + omitempty so
// it elides while the upstream copy has not been materialized yet (the composer
// omits an unresolved embed); once the ripple recomposes, it carries the
// allow-listed [id, code, name]. The Result→Response mapping keys the nested
// segment by the Go field name "UpstreamMirror" (the view's .As), so the field
// name — not the json tag — is the mapping handle.
type FindGadgetEmbeddedByIDResponse struct {
	fwresponses.Auto
	ID             string                      `json:"id"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code           string                      `json:"code"     example:"WIDGET-001"`
	Name           string                      `json:"name"     example:"Widget One"`
	Category       string                      `json:"category" example:"tools"`
	Status         string                      `json:"status"   example:"active"`
	UpstreamMirror *GadgetUpstreamMirrorOutput `json:"upstreamMirror,omitempty"`
}

func (FindGadgetEmbeddedByIDResponse) FromResult(r appqa.FindGadgetByIDResult) FindGadgetEmbeddedByIDResponse {
	return fwresponses.AutoFromResult[FindGadgetEmbeddedByIDResponse](r)
}

// GadgetUpstreamMirrorOutput is the nested projection of the `upstream_gadgets`
// mirror. Only [id, code, name] survive the subscription filter — category and
// status are intentionally absent, which is the visible proof that the upstream
// projection is filtered. Field names match the external schema's Go names (ID
// from ID, Code/Name from the declared fields).
type GadgetUpstreamMirrorOutput struct {
	ID   string `json:"id"   example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code string `json:"code" example:"WIDGET-001"`
	Name string `json:"name" example:"Widget One"`
}
