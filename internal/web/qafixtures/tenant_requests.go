//go:build qa

package qafixtures

import (
	"time"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// The wire shape of the Tenant fixture. The two probe fields (oldStatusSeen /
// oldPlanSeen) are ordinary read fields — the suite compares them against the
// relational columns to prove the projection carries what the row carries.

type TenantSeatRequest struct {
	Label string `json:"label" validate:"required" example:"seat-a"`
	Seat  int    `json:"seat" example:"1"`
}

type InsertTenantRequest struct {
	Code   string              `json:"code" validate:"required" example:"TN-1001"`
	Status string              `json:"status" validate:"required" example:"trial"`
	Plan   string              `json:"plan" example:"starter"`
	Seats  []TenantSeatRequest `json:"seats"`
}

func (r InsertTenantRequest) ToCommand() *appqa.InsertTenantCommand {
	seats := make([]appqa.TenantSeatInput, 0, len(r.Seats))
	for _, s := range r.Seats {
		seats = append(seats, appqa.TenantSeatInput{Label: s.Label, Seat: s.Seat})
	}
	return &appqa.InsertTenantCommand{Code: r.Code, Status: r.Status, Plan: r.Plan, Seats: seats}
}

// UpdateTenantRequest is the full-body PUT. status="closing" is the value that
// asks the domain to finish the write as an archive.
type UpdateTenantRequest struct {
	Code   string `json:"code" validate:"required" example:"TN-1001"`
	Status string `json:"status" validate:"required" example:"active"`
	Plan   string `json:"plan" example:"growth"`
}

func (r UpdateTenantRequest) ToCommand() *appqa.UpdateTenantCommand {
	return &appqa.UpdateTenantCommand{Code: r.Code, Status: r.Status, Plan: r.Plan}
}

type TenantWriteResponse struct {
	ID            string `json:"id"`
	Code          string `json:"code"`
	Status        string `json:"status"`
	Plan          string `json:"plan"`
	OldStatusSeen string `json:"oldStatusSeen"`
	OldPlanSeen   string `json:"oldPlanSeen"`
}

func (TenantWriteResponse) FromResult(r appqa.TenantResult) TenantWriteResponse {
	return TenantWriteResponse{
		ID:            r.ID.Value(),
		Code:          r.Code,
		Status:        r.Status,
		Plan:          r.Plan,
		OldStatusSeen: r.OldStatusSeen,
		OldPlanSeen:   r.OldPlanSeen,
	}
}

type FindTenantsRequest struct {
	Code   *string `query:"code" filter:"eq,contains"`
	Status *string `query:"status" filter:"eq"`
	Plan   *string `query:"plan" filter:"eq"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	OrderBy         *string `query:"orderBy"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindTenantsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindTenantsQuery {
	return &appqa.FindTenantsQuery{Criteria: criteria}
}

type TenantSeatResponse struct {
	ID        *string    `json:"id,omitempty"`
	Label     *string    `json:"label,omitempty"`
	Seat      *int       `json:"seat,omitempty"`
	DeletedAt *time.Time `json:"deletedAt,omitempty"`
}

type FindTenantsResponse struct {
	fwresponses.Auto
	ID            *string              `json:"id,omitempty"`
	Code          *string              `json:"code,omitempty"`
	Status        *string              `json:"status,omitempty"`
	Plan          *string              `json:"plan,omitempty"`
	OldStatusSeen *string              `json:"oldStatusSeen,omitempty"`
	OldPlanSeen   *string              `json:"oldPlanSeen,omitempty"`
	DeletedAt     *time.Time           `json:"deletedAt,omitempty"`
	TenantSeats   []TenantSeatResponse `json:"tenantSeats,omitempty"`
}

func (FindTenantsResponse) FromResult(r appqa.FindTenantsResult) FindTenantsResponse {
	return fwresponses.AutoFromResult[FindTenantsResponse](r)
}

type FindTenantByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindTenantByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindTenantByIDQuery {
	return &appqa.FindTenantByIDQuery{Criteria: criteria}
}
