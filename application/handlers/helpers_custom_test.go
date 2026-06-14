package handlers

import (
	"context"
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// errNotFound is a sentinel the fakeRepo returns from FindByEmail when the
// caller hasn't pre-loaded a row — keeps tests linear by avoiding the
// fwinfra.NotFoundError envelope which would require importing
// infrastructure exception helpers.
var errNotFound = errors.New("user not found")

// fakeRepo is the test double for the apphandlers.UserCustomRepository
// interface. Counters let each test assert which write methods reached the
// repo; the foundUser fields seed FindByEmail / FindArchivedByEmail with a
// preconstructed *User so the handler chain can exercise the application
// layer without pgx in the loop.
type fakeRepo struct {
	insertCalled    int
	updateCalled    int
	deleteCalled    int
	archiveCalled   int
	unarchiveCalled int

	insertErr    error
	updateErr    error
	deleteErr    error
	archiveErr   error
	unarchiveErr error

	foundUser         *appdomain.User
	foundArchivedUser *appdomain.User
}

func (r *fakeRepo) Insert(_ domain.Context, _ domain.Insertable, _ ...persistence.WriteOption[*appdomain.User]) (domain.ID, error) {
	r.insertCalled++
	if r.insertErr != nil {
		return domain.ID{}, r.insertErr
	}
	return domain.NewID(uuid.NewString()), nil
}

func (r *fakeRepo) Update(_ domain.Context, _ domain.Updatable, _ ...persistence.WriteOption[*appdomain.User]) error {
	r.updateCalled++
	return r.updateErr
}

func (r *fakeRepo) Delete(_ domain.Context, _ domain.Deletable, _ ...persistence.WriteOption[*appdomain.User]) error {
	r.deleteCalled++
	return r.deleteErr
}

func (r *fakeRepo) Archive(_ domain.Context, _ domain.Archivable, _ ...persistence.WriteOption[*appdomain.User]) error {
	r.archiveCalled++
	return r.archiveErr
}

func (r *fakeRepo) Unarchive(_ domain.Context, _ domain.Unarchivable, _ ...persistence.WriteOption[*appdomain.User]) error {
	r.unarchiveCalled++
	return r.unarchiveErr
}

func (r *fakeRepo) FindByID(domain.ID) (*appdomain.User, error) {
	if r.foundUser == nil {
		return nil, errNotFound
	}
	return r.foundUser, nil
}

func (r *fakeRepo) FindByEmail(string) (*appdomain.User, error) {
	if r.foundUser == nil {
		return nil, errNotFound
	}
	return r.foundUser, nil
}

func (r *fakeRepo) FindArchivedByEmail(string) (*appdomain.User, error) {
	if r.foundArchivedUser == nil {
		return nil, errNotFound
	}
	return r.foundArchivedUser, nil
}

func (r *fakeRepo) New() *appdomain.User {
	return &appdomain.User{}
}

// fakeService satisfies appdomain.UserService. EmailExists always returns
// false so happy-path tests do not have to thread a real Postgres pool.
type fakeService struct {
	domain.ServiceBase
}

func (fakeService) EmailExists(string, *domain.ID) bool { return false }

// newPersistedUser produces a User with an ID, valid root fields, and a
// single Address — the typical "loaded from DB" snapshot used by every
// FindByEmail test. Email matches the regex User.BuildRules enforces, so
// the update/patch lifecycle survives IfInsertOrUpdate validation.
func newPersistedUser(t testHelper) *appdomain.User {
	t.Helper()
	phone := "14155552671"
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: &phone,
	}
	u.SetID(domain.NewID(uuid.NewString()))
	u.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{
			ID:           uuid.NewString(),
			Street:       "1 Infinite Loop",
			Number:       "1",
			Neighborhood: "Mariani",
			City:         "Cupertino",
			State:        "CA",
			ZipCode:      "95014",
			Country:      "US",
		},
	})
	return u
}

// testHelper is the minimal interface the *testing.T satisfies. Declared
// locally to avoid importing "testing" inside production-code surfaces
// indirectly through this helper file's signature.
type testHelper interface{ Helper() }

func testCtx() *configuration.AppContext {
	return configuration.NewAppContextWithRandomID(configuration.LangPTBR)
}

// fakeViewReader satisfies queries.ViewReader for read-handler tests.
// Counters track invocations; gotView/gotCriteria/gotID expose what the
// handler asked for so the test can assert the filter seam wrote the
// expected criteria. Both ReadPage and ReadByID record the same
// ReadCriteria — symmetric with the production port.
type fakeViewReader struct {
	readPageCalled int
	readByIDCalled int

	gotView     string
	gotCriteria queries.ReadCriteria
	gotID       string

	pageToReturn queries.Page
	pageErr      error

	docToReturn map[string]any
	docFound    bool
	docErr      error
}

func (r *fakeViewReader) ReadPage(_ context.Context, view string, c queries.ReadCriteria) (queries.Page, error) {
	r.readPageCalled++
	r.gotView = view
	r.gotCriteria = c
	return r.pageToReturn, r.pageErr
}

func (r *fakeViewReader) ReadByID(_ context.Context, view, id string, c queries.ReadCriteria) (map[string]any, bool, error) {
	r.readByIDCalled++
	r.gotView = view
	r.gotID = id
	r.gotCriteria = c
	return r.docToReturn, r.docFound, r.docErr
}
