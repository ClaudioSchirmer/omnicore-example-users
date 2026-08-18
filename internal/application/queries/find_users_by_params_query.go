package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUsersByParamsQuery is the application-side transport for a paged user
// read. The wrapper QueryWithParams has already parsed the query string
// into the embedded ReadCriteria; ToCriteria(ctx) then applies identity-derived
// overlays — the Query is the only layer below the web boundary that may consume
// ctx, and the criteria is what reaches the ViewReader, so security belongs here.
type FindUsersByParamsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

// ToCriteria showcases field-level read access: Phone is restricted to
// principals carrying users:admin. Restrict removes the field from the read
// (projection + sort + filter), so it surfaces in neither the JSON nor the
// CSV/XLSX export for a non-admin; an active reference (?orderBy=phone /
// ?fields=phone) returns 403. Dev-safe: under auth-disabled dev the Identity is
// nil and everyone is trusted, so Phone is not restricted there.
func (q FindUsersByParamsQuery) ToCriteria(ctx *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	crit := q.Criteria
	// Restrict mutates crit in place (scrubbing Phone from projection/sort/filter)
	// and returns the 403 only on an active reference. Threading its error straight
	// into the single return keeps the refusal impossible to drop by accident.
	var err error
	if id := ctx.Identity(); id != nil && !id.HasPermission("users:admin") {
		err = crit.Restrict("Phone")
	}
	return crit, err
}

// FromQueryResult is the read-side twin of a command's FromEntity: the framework
// fills one FindUsersByParamsResult per returned document and hands it here
// BEFORE any transport surface sees it — derived/computed fields and
// ctx-aware shaping belong in this seat so REST, gRPC, GraphQL and the
// CSV/XLSX exports all render the same values. This listing needs no
// computation: return the filled Result unchanged.
func (q FindUsersByParamsQuery) FromQueryResult(_ *configuration.AppContext, r FindUsersByParamsResult) (FindUsersByParamsResult, error) {
	return r, nil
}

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindUsersByParamsResult is the application-layer Result of one User view
// document in the paged listing — the read-side twin of a command Result:
// pure data, NO wire tags (wire naming belongs to the web Response), field
// names identical to the canonical document's Go keys. Every field is a
// pointer (or slice) because the endpoint opts into `?fields=` — a
// projected-out column must fill as absent, not as a zero value (the
// framework boot-guards this sparse contract on Result AND Response).
type FindUsersByParamsResult struct {
	ID                    *string
	Name                  *string
	Email                 *string
	Phone                 *string
	Document              *string
	Ethnicity             *string
	UserName              *string
	UserProfile           *int
	EmailNotification     *bool
	SmsNotification       *bool
	NotificationEmail     *string
	NotificationFrequency *int
	Addresses             []FindUsersByParamsAddressResult
}

// FindUsersByParamsAddressResult is the nested Result shape of one Address
// inside a list item — same sparse-pointer rule, recursively.
type FindUsersByParamsAddressResult struct {
	ID           *string
	Label        *string
	Street       *string
	Number       *string
	Complement   *string
	Neighborhood *string
	City         *string
	State        *string
	ZipCode      *string
	Country      *string
	AddressType  *string
}
