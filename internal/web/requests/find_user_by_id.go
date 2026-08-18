package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUserByIDRequest is the wire allowlist for GET /users/:id. The only
// reserved query parameter is ?includeArchived=true; anything else produces
// 400 at the wrapper before this DTO is touched.
type FindUserByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// AppContext flows into the application layer via Query.ToCriteria(ctx),
// where identity-derived overlays (tenant id, owner id) layer onto the
// criteria. Symmetric to InsertUserRequest.ToCommand on the write side.
func (r FindUserByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindUserByIDQuery {
	return &queries.FindUserByIDQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUserByIDResponse is the wire projection of the User view document for
// GET /users/:id — mapped from the application Result by FromResult below.
// The Result already speaks Go field names (the reader translated every
// physical column via UserSchema()/AddressSchema(): mail → Email, zip_code →
// ZipCode, the embed doc field "addresses" → the Go segment "Addresses"), so
// the only tag governing the mapping is json:"<wire>" — the outgoing JSON
// name. The three-name model (json ↔ Go ↔ column) stays resolved at the two
// membranes (web json↔Go, infra Go↔column).
//
// Co-location convention: Response and Request live in the same file; the
// nested address shape stays per-endpoint to keep the by-id and list
// surfaces independent if either evolves.
type FindUserByIDResponse struct {
	fwresponses.Auto
	ID       string  `json:"id"                          example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name     string  `json:"name"                        example:"Alice Pereira"`
	Email    string  `json:"email"                       example:"alice@example.com"`
	Phone    *string `json:"phone,omitempty"             example:"14155552671"`
	Document string  `json:"document"                    example:"12345678901"`
	// Value-object-typed response fields — proving a read DTO may carry the VO
	// type (not just a raw scalar): they arrive already converged from the
	// application Result (an out-of-set enum became Unknown at the fill, so
	// every surface agrees), and OpenAPI/GraphQL describe them by their
	// underlying scalar.
	Ethnicity             vos.Ethnicity               `json:"ethnicity"                       example:"white"`
	UserName              string                      `json:"userName"                        example:"alice"`
	UserProfile           vos.UserProfile             `json:"userProfile"                     example:"1"`
	EmailNotification     *bool                       `json:"emailNotification,omitempty"     example:"true"`
	SmsNotification       *bool                       `json:"smsNotification,omitempty"       example:"false"`
	NotificationEmail     *vos.Email                  `json:"notificationEmail,omitempty"     example:"alice.notify@example.com"`
	NotificationFrequency *vos.NotificationFrequency  `json:"notificationFrequency,omitempty" example:"2"`
	Addresses             []FindUserByIDAddressOutput `json:"addresses"`
}

// FromResult is the wire mapping seat — the read-side twin of the command
// Responses' FromResult, delegating to the generic name-based mapper.
func (FindUserByIDResponse) FromResult(r queries.FindUserByIDResult) FindUserByIDResponse {
	return fwresponses.AutoFromResult[FindUserByIDResponse](r)
}

// FindUserByIDAddressOutput is the nested wire shape of one Address inside
// the by-id response. The Result segment it maps from already carries Go
// field names (the reader translated zip_code → ZipCode via AddressSchema),
// so the json: tag is only the outgoing wire name.
type FindUserByIDAddressOutput struct {
	ID           string          `json:"id"                   example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Label        *string         `json:"label,omitempty"      example:"home"`
	Street       string          `json:"street"               example:"1 Infinite Loop"`
	Number       string          `json:"number"               example:"1"`
	Complement   *string         `json:"complement,omitempty" example:"Apt 4B"`
	Neighborhood string          `json:"neighborhood"         example:"Mariani"`
	City         string          `json:"city"                 example:"Cupertino"`
	State        string          `json:"state"                example:"CA"`
	ZipCode      string          `json:"zipCode"              example:"95014"`
	Country      string          `json:"country"              example:"US"`
	AddressType  vos.AddressType `json:"addressType"          example:"residential"`
}
