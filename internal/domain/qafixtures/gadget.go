//go:build qa

// Package qafixtures holds QA-only domain fixtures that exercise framework
// features the canonical User/Employee aggregates do not. Everything here is
// gated behind the `qa` build tag so the canonical binary never compiles it.
package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Gadget is a FLAT aggregate root (NOT a SharedBase) — deliberately simpler
// than User. It embeds domain.AggregateRoot only for the BaseEntity machinery
// (id accessors, notification context, rules). It declares NO aggregate
// children and does NOT implement domain.AggregateRootProvider, so the write
// path takes the simple single-table route (table `gadgets`, see
// infra/qafixtures). Its whole reason to exist is to exercise (1) the full
// filter-operator vocabulary on its list endpoint and (2) the in-TX lifecycle
// hooks (AfterBegin + BeforeCommit) on both the Auto and the manual paths.
//
// Fields map 1:1 to columns via infra/qafixtures.GadgetSchema (Go↔column map);
// no db: tags. Code is a lexically ordered natural-ish key (unique at the DB).
type Gadget struct {
	domain.AggregateRoot
	Code     string
	Name     string
	Category string
	Status   string
}

// Modes advertises the lifecycle verbs the aggregate supports. SoftDelete on
// the schema pairs with ModeArchive/ModeUnarchive (the framework cross-checks
// Modes() ⟺ SoftDelete at repository construction).
func (g *Gadget) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
		domain.ModeDelete,
		domain.ModeArchive,
		domain.ModeUnarchive,
	}
}

// gadgetStatuses is the closed set Status must fall into — a pure domain rule.
var gadgetStatuses = map[string]struct{}{
	"active":   {},
	"inactive": {},
	"retired":  {},
}

// BuildRules keeps the aggregate non-trivial: Code + Name are required, and
// Status must be one of the closed set. Both notifications are framework
// built-ins (already carried in the framework's translation catalog), so no
// service translation entry is needed. RequiredFieldNotification defaults to
// Validation → 422; SchemaViolationNotification carries the rejected value.
func (g *Gadget) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if g.Code == "" {
			r.AddNotification("Code", domain.RequiredFieldNotification{})
		}
		if g.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
		if _, ok := gadgetStatuses[g.Status]; !ok {
			r.AddNotification("Status", domain.SchemaViolationNotification{}, g.Status)
		}
	})
}
