package domain

import "github.com/ClaudioSchirmer/omnicore/domain"

// Notifications specific to the User aggregate root.
// Each struct embeds DomainNotificationBase so reflect.TypeOf(...).Name()
// becomes the translation key (e.g. "DocumentCannotChangeNotification").
// The shared Person field notifications live beside their rule in
// internal/domain/vos; the aggregate value objects' notifications (State,
// Country, TerminationBeforeHire) live in internal/domain/aggregatevos.

// DocumentCannotChangeNotification is the canonical transition-aware invariant
// of this example: Document is the shared Person identity's natural key, so it
// is immutable once the user is created. Fired by User.BuildRules inside
// r.IfUpdate when domain.Old(u).Document differs from u.Document. Default
// Semantic (Validation → 422) — the wire field carries the rejected value to
// make it visible to the consumer.
//
// Showcases domain.Old[T]: the framework's Get* path stores the loaded entity
// as a typed read-only ghost before applying any mutation, so the comparison
// "old vs new" inside BuildRules works the same on PUT and PATCH.
type DocumentCannotChangeNotification struct{ domain.DomainNotificationBase }

// DuplicateAddressNotification is emitted by User.AddAddress when the incoming
// address has the same business identity as one already in the aggregate. Phase
// 20: aggregate invariants spanning children live in domain methods on the
// root, not in the framework's primitives. Default Semantic (Validation → 422)
// fits "this batch carries a duplicate" — Conflict (409) would also be
// defensible if the source of truth were the existing collection rather than
// the request shape.
type DuplicateAddressNotification struct{ domain.DomainNotificationBase }
