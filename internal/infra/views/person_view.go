package views

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/schemas"
)

// PersonView declares the ALL-IN-ONE identity projection — the SharedBaseView
// rooted at the persons base: one document per shared Person carrying the
// shared fields flat at the root, the shared addresses nested at the root, and
// one sub-document per role ("User" with its notification sibling flat,
// "Employee" with its bank sibling flat + dependents/jobHistories nested).
//
//   - _id = the person's deterministic id (UUIDv5(document)) — the same id the
//     shared-PK roles carry;
//   - an absent role is an explicit null segment; an archived role stores its
//     deleted_at and is hidden on default reads (?includeArchived surfaces it);
//   - the document itself is gated by the base's deleted_at — the person hides
//     only when EVERY role is archived (the write side's convergence);
//   - every role event (either role table) recomposes this document, and the
//     persons base events route to it as root events.
//
// A fresh schemas.PersonBase() instance is fine — Role() checks declaration
// equivalence against each role's own base instance at declaration time.
//
// Called exactly once per process via bootstrap.NewPersonsFeature.
func PersonView() *query.ViewDefinition {
	return query.SharedBaseView(schemas.PersonBase(), "persons").
		Role(schemas.UserSchema()).
		Role(schemas.EmployeeSchema()).
		Version(1).
		Indexes(
			query.Index("document"),
			query.Index("name"),
			query.TextIndex("name", "email").DefaultLanguage("english"),
		)
}
