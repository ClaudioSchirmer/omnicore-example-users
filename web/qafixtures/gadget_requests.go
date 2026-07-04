//go:build qa

// Package qafixtures (web layer) owns the wire surface of the QA-only Gadget
// aggregate: request/response DTOs (JSON + filter tags) and the route mount.
// Gated behind the `qa` build tag.
package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/application/qafixtures"
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
	Code     *string `query:"code"     filter:"eq,in,nin,gte,lte,gt,lt,startswith"`
	Name     *string `query:"name"     filter:"eq,ne,startswith,contains,icontains,istartswith,ine"`
	Category *string `query:"category" filter:"eq,in,iin,inin,ieq"`
	Status   *string `query:"status"   filter:"eq,ne,ieq,ine"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindGadgetsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetsQuery {
	return &appqa.FindGadgetsQuery{Criteria: criteria}
}

// FindGadgetsResponse is the per-item wire projection of the list read. Every
// field is *T + ,omitempty so `?fields=` sparse rendering elides absent leaves.
type FindGadgetsResponse struct {
	ID       *string `json:"id,omitempty"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code     *string `json:"code,omitempty"     example:"WIDGET-001"`
	Name     *string `json:"name,omitempty"     example:"Widget One"`
	Category *string `json:"category,omitempty" example:"tools"`
	Status   *string `json:"status,omitempty"   example:"active"`
}

// ─── By id ───────────────────────────────────────────────────────────────────

// FindGadgetByIDRequest is the wire allowlist for GET /qa/gadgets/:id — only
// ?includeArchived is recognized.
type FindGadgetByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindGadgetByIDRequest) ToQuery() *appqa.FindGadgetByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &appqa.FindGadgetByIDQuery{IncludeArchived: arch}
}

// FindGadgetByIDResponse is the wire projection of the by-id read.
type FindGadgetByIDResponse struct {
	ID       string `json:"id"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code     string `json:"code"     example:"WIDGET-001"`
	Name     string `json:"name"     example:"Widget One"`
	Category string `json:"category" example:"tools"`
	Status   string `json:"status"   example:"active"`
}

// ─── Composed by id (root gadget + one-to-one upstream mirror) ───────────────

// FindGadgetComposedByIDResponse is the wire projection of the composed read
// (GET /qa/gadgets-composed/:id) against the `gadgets_composed` view. It is the
// flat gadget PLUS the one-to-one `upstreamMirror` embed the composer fills from
// the `upstream_gadgets` projection. UpstreamMirror is a pointer + omitempty so
// it elides while the upstream copy has not been materialized yet (the composer
// omits an unresolved embed); once the ripple recomposes, it carries the
// allow-listed [id, code, name]. AutoFromDoc keys the nested segment by the Go
// field name "UpstreamMirror" (the view's .As), so the field name — not the json
// tag — is the mapping handle.
type FindGadgetComposedByIDResponse struct {
	ID             string                      `json:"id"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code           string                      `json:"code"     example:"WIDGET-001"`
	Name           string                      `json:"name"     example:"Widget One"`
	Category       string                      `json:"category" example:"tools"`
	Status         string                      `json:"status"   example:"active"`
	UpstreamMirror *GadgetUpstreamMirrorOutput `json:"upstreamMirror,omitempty"`
}

// GadgetUpstreamMirrorOutput is the nested projection of the `upstream_gadgets`
// mirror. Only [id, code, name] survive the subscription filter — category and
// status are intentionally absent, which is the visible proof that the upstream
// projection is filtered. Field names match the external schema's Go names (ID
// from PK, Code/Name from the declared fields).
type GadgetUpstreamMirrorOutput struct {
	ID   string `json:"id"   example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code string `json:"code" example:"WIDGET-001"`
	Name string `json:"name" example:"Widget One"`
}
