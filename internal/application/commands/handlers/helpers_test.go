package handlers

import (
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// errNotFound is a sentinel the fakeRepo returns from FindByDocument when the
// caller hasn't pre-loaded a row — keeps tests linear by avoiding the
// fwinfra.NotFoundError envelope which would require importing
// infrastructure exception helpers.
var errNotFound = errors.New("user not found")

// fakeRepo is the test double for the handlers' ScopedUserRepository: its
// Scope returns itself, it satisfies the pure appdomain.UserCustomRepository
// port (Reader + Writer + document lookups), and it implements the
// persistence.SharedBaseInsertLoader capability the insert handler needs.
// Counters let each test assert which write methods reached the repo; the
// foundUser fields seed FindByDocument / FindArchivedByDocument /
// LoadForSharedBaseInsert with a preconstructed *User so the handler chain can
// exercise the application layer without a database.
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

// Scope binds the request scope and returns the pure appdomain.UserCustomRepository
// — here the same double, so the counters and seeded reads are shared.
func (r *fakeRepo) Scope(_ *configuration.AppContext, _ ...persistence.WriteOption[*appdomain.User]) appdomain.UserCustomRepository {
	return r
}

func (r *fakeRepo) Insert(_ domain.Insertable) (domain.ID, error) {
	r.insertCalled++
	if r.insertErr != nil {
		return domain.ID{}, r.insertErr
	}
	return domain.NewID(uuid.NewString()), nil
}

func (r *fakeRepo) Update(_ domain.Updatable) error {
	r.updateCalled++
	return r.updateErr
}

func (r *fakeRepo) Delete(_ domain.Deletable) error {
	r.deleteCalled++
	return r.deleteErr
}

func (r *fakeRepo) Archive(_ domain.Archivable) error {
	r.archiveCalled++
	return r.archiveErr
}

func (r *fakeRepo) Unarchive(_ domain.Unarchivable) error {
	r.unarchiveCalled++
	return r.unarchiveErr
}

func (r *fakeRepo) FindByID(domain.ID) (*appdomain.User, error) {
	if r.foundUser == nil {
		return nil, errNotFound
	}
	return r.foundUser, nil
}

func (r *fakeRepo) FindByDocument(string) (*appdomain.User, error) {
	if r.foundUser == nil {
		return nil, errNotFound
	}
	return r.foundUser, nil
}

func (r *fakeRepo) FindArchivedByDocument(string) (*appdomain.User, error) {
	if r.foundArchivedUser == nil {
		return nil, errNotFound
	}
	return r.foundArchivedUser, nil
}

// LoadForSharedBaseInsert satisfies persistence.SharedBaseInsertLoader: when a
// row is seeded via foundUser the load reports a WARM upsert (the person
// exists); otherwise it returns the fresh entity for a COLD insert.
func (r *fakeRepo) LoadForSharedBaseInsert(_ *configuration.AppContext, fresh *appdomain.User) (*appdomain.User, bool, error) {
	if r.foundUser != nil {
		return r.foundUser, true, nil
	}
	return fresh, false, nil
}

func (r *fakeRepo) New() *appdomain.User {
	return &appdomain.User{}
}

// fakeService is a trivial domain.Service. The User aggregate requires no
// service, so handlers can also receive nil; this double exists only so tests
// that wire a non-nil service keep compiling.
type fakeService struct {
	domain.ServiceBase
}

// newPersistedUser produces a User with an ID, valid root fields, and a
// single Address — the typical "loaded from DB" snapshot used by every
// FindByDocument test. The shared Person fields + role UserName + immutable
// Document are all set so the update/patch lifecycle survives validation.
func newPersistedUser(t testHelper) *appdomain.User {
	t.Helper()
	phone := "14155552671"
	u := &appdomain.User{
		Name:     "Jane Doe",
		Email:    "jane@example.com",
		Phone:    &phone,
		Document: "10000000001",
		UserName: "jane",
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
