package queries

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindPersonsByParamsQuery is the application-side transport for a paged read
// of the all-in-one person view (the SharedBaseView over the shared Person
// identity). The wrapper has already parsed the query string into the embedded
// ReadCriteria; ToCriteria(ctx) is where identity-derived overlays would layer
// on — none here.
type FindPersonsByParamsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindPersonsByParamsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the mandatory read-side projection hook — the twin of a
// command's FromEntity. Nothing to compute on this listing.
func (q FindPersonsByParamsQuery) FromQueryResult(_ *configuration.AppContext, r FindPersonsByParamsResult) (FindPersonsByParamsResult, error) {
	return r, nil
}

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindPersonsByParamsResult is the application-layer Result of one person
// document (the SharedBaseView projection). Tagless; sparse pointers because
// the endpoint opts into `?fields=`. Shared fields sit flat at the root, the
// shared addresses nest at the root, and each role is an optional
// sub-object — the field name IS the role segment ("User"/"Employee"), which
// is how the framework's fill keys it.
type FindPersonsByParamsResult struct {
	ID        *string
	Name      *string
	Email     *string
	Phone     *string
	Document  *string
	Ethnicity *string

	Addresses []FindUsersByParamsAddressResult
	User      *PersonUserResult
	Employee  *PersonEmployeeResult
}

// PersonUserResult is the User role segment: role-private fields plus the
// notification sibling flat, mirroring the composed sub-document.
type PersonUserResult struct {
	ID                    *string
	UserName              *string
	UserProfile           *int
	EmailNotification     *bool
	SmsNotification       *bool
	NotificationEmail     *string
	NotificationFrequency *int
	DeletedAt             *time.Time
}

// PersonEmployeeResult is the Employee role segment: role fields, the bank
// sibling flat, and the role-owned collections nested inside.
type PersonEmployeeResult struct {
	ID             *string
	EmployeeNumber *string
	Bank           *string
	Branch         *string
	Account        *string
	Pix            *string
	DeletedAt      *time.Time

	Dependents   []DependentResult
	JobHistories []JobHistoryResult
}
