// Package responses holds wire-format response DTOs for the manual showcase
// routes mounted under /showcase/users-custom/*. Keeping them out of
// web/requests/ is intentional — request DTOs carry the parse direction
// (wire → application); these carry the render direction (application → wire).
// The boundary is the same: only this package declares JSON tags on the
// outbound shape.
//
// The canonical /users/* routes do not have a parallel here because each of
// their endpoints declares its own per-endpoint Response co-located with the
// Request. The manual showcase deliberately shares a single response across
// the three body verbs (Insert, Update, Patch) to demonstrate that the
// Result-intermediate pattern composes with a shared wire shape — only the
// Result granularity is mandatory; the Response granularity is a per-service
// choice. Archive / Unarchive / Delete reach the wire as fwresults.None and
// emit the success envelope without a `data` field.
package responses

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// UserCustomResponse is the wire shape returned by every manual body-emitting
// handler (Insert, Update, Patch). Mirrors the User aggregate's current state
// at the moment the handler succeeded: root fields populated, address children
// expanded as AddressCustomResponse.
type UserCustomResponse struct {
	ID                domain.ID               `json:"id"                          example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name              string                  `json:"name"                        example:"Alice Pereira"`
	Email             string                  `json:"email"                       example:"alice@example.com"`
	Phone             *string                 `json:"phone,omitempty"             example:"14155552671"`
	Document          string                  `json:"document"                    example:"12345678901"`
	UserName          string                  `json:"userName"                    example:"alice"`
	EmailNotification *bool                   `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool                   `json:"smsNotification,omitempty"   example:"false"`
	Addresses         []AddressCustomResponse `json:"addresses"`
}

// AddressCustomResponse is the wire shape of one Address row inside UserCustomResponse.
// Optional fields use the same nil-omit policy as the request DTOs so the
// payload round-trips through PUT/PATCH without phantom keys.
type AddressCustomResponse struct {
	ID           string  `json:"id"                   example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Label        *string `json:"label,omitempty"      example:"home"`
	Street       string  `json:"street"               example:"1 Infinite Loop"`
	Number       string  `json:"number"               example:"1"`
	Complement   *string `json:"complement,omitempty" example:"Apt 4B"`
	Neighborhood string  `json:"neighborhood"         example:"Mariani"`
	City         string  `json:"city"                 example:"Cupertino"`
	State        string  `json:"state"                example:"CA"`
	ZipCode      string  `json:"zipCode"              example:"95014"`
	Country      string  `json:"country"              example:"US"`
}

// FromResult is the application Result → wire Response mapper. Pure
// field-by-field assignment — no domain types, no aggregate primitives, no
// nil-checks beyond the per-field optional shape. The handler is responsible
// for producing a populated Result; the wire layer just renames the package.
//
// Symmetric inverse of Request.ToCommand: ToCommand is wire → application;
// FromResult is application → wire. The two boundaries keep the web layer
// JSON-aware and the application layer JSON-free.
func FromResult(r commands.UserCustomResult) UserCustomResponse {
	addrs := make([]AddressCustomResponse, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = AddressCustomResponse{
			ID:           a.ID,
			Label:        a.Label,
			Street:       a.Street,
			Number:       a.Number,
			Complement:   a.Complement,
			Neighborhood: a.Neighborhood,
			City:         a.City,
			State:        a.State,
			ZipCode:      a.ZipCode,
			Country:      a.Country,
		}
	}
	return UserCustomResponse{
		ID:                r.ID,
		Name:              r.Name,
		Email:             r.Email,
		Phone:             r.Phone,
		Document:          r.Document,
		UserName:          r.UserName,
		EmailNotification: r.EmailNotification,
		SmsNotification:   r.SmsNotification,
		Addresses:         addrs,
	}
}
