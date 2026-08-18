package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// FindUserByIDQuery is the application-side transport for a by-id user read.
// QueryByIDBase supplies SetPathID (called by the wrapper from the URL
// segment) + GetID consumed by the framework's FindByIDQueryHandler.
// ContextName returns "User" so the 404 NotificationContext aligns with the
// identity the write side emits (Insert/Update/Delete notifications carry
// the same "User" context), instead of the plural collection name "users".
//
// ToCriteria(ctx) is the only layer below the web boundary that may consume
// *AppContext — JWT-derived overlays (tenant id, owner id) layer onto the
// returned ReadCriteria here. The handler forwards the criteria to
// ViewReader.ReadByID, which merges Filter into the {_id: id} +
// deleted_at gate; Limit/Sort/After/Before/Search/Projection are ignored
// by ReadByID by design (they only make sense on a paged read).
type FindUserByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindUserByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the read-side twin of a command's FromEntity: the framework
// fills FindUserByIDResult from the canonical document and hands it here
// before any transport surface sees it. Nothing to compute on this read.
func (q FindUserByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindUserByIDResult) (FindUserByIDResult, error) {
	return r, nil
}

func (q FindUserByIDQuery) ContextName() string { return "User" }

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindUserByIDResult is the application-layer Result of the by-id user read.
// Pure data, NO wire tags (the web Response owns wire naming); field names
// match the canonical document's Go keys. Non-sparse: the endpoint does not
// declare `?fields=`, so plain values are fine — an absent key fills as the
// zero value.
//
// Value-object-typed fields are deliberate: a Result may carry the VO type,
// and the framework's fill converges an out-of-set enum to Unknown at THIS
// layer, so every surface (REST, gRPC, GraphQL, CSV/XLSX) renders the same
// converged value.
type FindUserByIDResult struct {
	ID                    string
	Name                  string
	Email                 string
	Phone                 *string
	Document              string
	Ethnicity             vos.Ethnicity
	UserName              string
	UserProfile           vos.UserProfile
	EmailNotification     *bool
	SmsNotification       *bool
	NotificationEmail     *vos.Email
	NotificationFrequency *vos.NotificationFrequency
	Addresses             []AddressResult
}

// AddressResult is the Result shape of one Address sub-document, shared by
// the by-id user read and the by-id address reads.
type AddressResult struct {
	ID           string
	Label        *string
	Street       string
	Number       string
	Complement   *string
	Neighborhood string
	City         string
	State        string
	ZipCode      string
	Country      string
	AddressType  vos.AddressType
}
