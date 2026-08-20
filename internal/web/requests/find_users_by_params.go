package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUsersByParamsRequest declares the wire allowlist for GET /users via
// struct tags consumed by fwweb.QueryWithParams. Filterable fields
// carry a filter tag with the operators they accept; pagination/control
// keys carry only a query tag and are recognized by the framework's reserved
// set (limit/after/before/sort/fields/search/includeArchived).
//
// Nested embed groups mirror the Response side: a struct-typed field
// carrying a query:"prefix" tag (no filter:) is an embed group; each leaf
// inside contributes a wire key prefixed by its parent (so City below
// surfaces as ?addresses.city=Berlin). The wrapper maps the wire key to the
// Go field path (Addresses.City); the MongoViewReader then translates that
// Go path to the physical Mongo path (addresses.city) via the view's
// TableSchema — no PascalToSnake, no view: tag at this layer.
//
// The fields are tag carriers — the wrapper parses the query string directly
// into a ReadCriteria and hands it to ToQuery. AppContext-derived overlays
// (tenant id from a future JWT middleware) layer onto the criteria inside
// the Query's ToCriteria(ctx), consumed by the handler — ToQuery itself is
// pure body mapping, no ctx parameter.
type FindUsersByParamsRequest struct {
	Name        *string             `query:"name"        filter:"eq,startswith,icontains,istartswith" sort:"asc,desc"`
	Email       *string             `query:"email"       filter:"eq,in,ieq" sort:"asc,desc"`
	Document    *string             `query:"document"    filter:"eq,in,startswith" sort:"asc,desc"`
	Ethnicity   *string             `query:"ethnicity"   filter:"eq,in" sort:"asc,desc"`
	UserName    *string             `query:"userName"    filter:"eq,startswith,icontains" sort:"asc,desc"`
	UserProfile *int                `query:"userProfile" filter:"eq,in" sort:"asc,desc"`
	Addresses   AddressFilterParams `query:"addresses"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// AddressFilterParams is the embed-group counterpart of the Address output
// — same vocabulary, filter side. Wire keys land prefixed by the parent
// field's query tag, so ?addresses.city=Berlin and ?addresses.zipCode=10001
// become Go field paths (Addresses.City / Addresses.ZipCode); the reader
// translates them to the physical Mongo paths (addresses.city /
// addresses.zip_code) via the view's TableSchema — no view: declaration.
type AddressFilterParams struct {
	City        *string `query:"city"        filter:"eq,istartswith,icontains"`
	State       *string `query:"state"       filter:"eq,in"`
	Country     *string `query:"country"     filter:"eq,in"`
	ZipCode     *string `query:"zipCode"     filter:"eq,startswith"`
	AddressType *string `query:"addressType" filter:"eq,in"`
}

func (r FindUsersByParamsRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindUsersByParamsQuery {
	return &queries.FindUsersByParamsQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUsersByParamsResponse is the wire projection of one User view document
// in the GET /users list — mapped from the application Result by FromResult
// below, the SINGLE wire authority every surface consumes (REST, gRPC,
// GraphQL, CSV/XLSX). A field absent here exists on no wire.
//
// json:"<wire>" names the field on the outgoing envelope; exportLabelKey
// names the translation-catalog key the tabular exports render as the column
// header (reuse the entity's labelKey value to converge on the same
// translation; absent = the json name is the header).
//
// Every field — at every depth — is *T (or a slice) and carries ,omitempty
// because the Request DTO declares `?fields=` and the framework's boot
// guard enforces the sparse-render contract: when the consumer asks for a
// subset (`?fields=name,email`), Mongo strips the unwanted columns and
// encoding/json elides the absent values via the omitempty modifier.
// Without pointers + omitempty, a stripped `name` would still render as
// `"name":""` (zero value), defeating the point of the parameter.
type FindUsersByParamsResponse struct {
	fwresponses.Auto
	ID                    *string                          `json:"id,omitempty"                                       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name                  *string                          `json:"name,omitempty"                  exportLabelKey:"UserNameField"                  example:"Alice Pereira"`
	Email                 *string                          `json:"email,omitempty"                 exportLabelKey:"UserEmailField"                 example:"alice@example.com"`
	Phone                 *string                          `json:"phone,omitempty"                 exportLabelKey:"UserPhoneField"                 example:"14155552671"`
	Document              *string                          `json:"document,omitempty"              exportLabelKey:"UserDocumentField"              example:"12345678901"`
	Ethnicity             *string                          `json:"ethnicity,omitempty"             exportLabelKey:"PersonEthnicityField"             example:"white"`
	UserName              *string                          `json:"userName,omitempty"              exportLabelKey:"UserUserNameField"              example:"alice"`
	UserProfile           *int                             `json:"userProfile,omitempty"           exportLabelKey:"UserProfileField"           example:"1"`
	EmailNotification     *bool                            `json:"emailNotification,omitempty"     exportLabelKey:"UserEmailNotificationField"     example:"true"`
	SmsNotification       *bool                            `json:"smsNotification,omitempty"       exportLabelKey:"UserSmsNotificationField"       example:"false"`
	NotificationEmail     *string                          `json:"notificationEmail,omitempty"     exportLabelKey:"UserNotificationEmailField"     example:"alice.notify@example.com"`
	NotificationFrequency *int                             `json:"notificationFrequency,omitempty" exportLabelKey:"UserNotificationFrequencyField" example:"2"`
	Addresses             []FindUsersByParamsAddressOutput `json:"addresses,omitempty"`
}

// FromResult is the wire mapping seat — the read-side twin of the command
// Responses' FromResult. fwresponses.AutoFromResult is the generic name-based mapper
// (Result field → same-named Response field, emitted under its json tag);
// a Response needing more than the tags writes the mapping by hand instead.
func (FindUsersByParamsResponse) FromResult(r queries.FindUsersByParamsResult) FindUsersByParamsResponse {
	return fwresponses.AutoFromResult[FindUsersByParamsResponse](r)
}

// FindUsersByParamsAddressOutput is the nested wire shape of one Address
// inside a list item. Same pointer + omitempty rule applies recursively:
// nested filters like `?fields=addresses.city` only populate City, and
// every other field of the Address subdoc renders absent rather than as
// the empty string. The MongoViewReader already translated each physical
// column back to its Go field name via the view's AddressSchema (zip_code →
// ZipCode), so the Result carries the Go field name and the json: tag is
// only the outgoing wire name — no view: source-key override.
type FindUsersByParamsAddressOutput struct {
	ID           *string `json:"id,omitempty"                     example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Label        *string `json:"label,omitempty"        exportLabelKey:"AddressLabelField"        example:"home"`
	Street       *string `json:"street,omitempty"       exportLabelKey:"AddressStreetField"       example:"1 Infinite Loop"`
	Number       *string `json:"number,omitempty"       exportLabelKey:"AddressNumberField"       example:"1"`
	Complement   *string `json:"complement,omitempty"   exportLabelKey:"AddressComplementField"   example:"Apt 4B"`
	Neighborhood *string `json:"neighborhood,omitempty" exportLabelKey:"AddressNeighborhoodField" example:"Mariani"`
	City         *string `json:"city,omitempty"         exportLabelKey:"AddressCityField"         example:"Cupertino"`
	State        *string `json:"state,omitempty"        exportLabelKey:"AddressStateField"        example:"CA"`
	ZipCode      *string `json:"zipCode,omitempty"      exportLabelKey:"AddressZipCodeField"      example:"95014"`
	Country      *string `json:"country,omitempty"      exportLabelKey:"AddressCountryField"      example:"US"`
	AddressType  *string `json:"addressType,omitempty"  exportLabelKey:"AddressTypeField"  example:"residential"`
}
