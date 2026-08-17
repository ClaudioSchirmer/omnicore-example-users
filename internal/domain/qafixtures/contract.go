//go:build qa

package qafixtures

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// The COMPOSITE VALUE OBJECT family — a value object whose value spans more
// than one persisted column. Nothing in this file is framework-aware beyond the
// two existing value-object contracts: a composite is a plain struct that owns
// its rule (IsValid) and declares NO Value(), and the framework's automatic
// field discovery already finds and validates it. Which columns it occupies is
// declared once, in the TableSchema (see internal/infra/qafixtures) — the
// domain never learns it is decomposed.
//
// The fixture deliberately covers every branch of the design in one aggregate:
//
//	Code    ContractCode  — a SCALAR value object, the contrast case (one column)
//	Salary  Money         — a MANDATORY composite, with an ENUM value-object part
//	Trial   *Period       — an OPTIONAL composite, with one mandatory and one
//	                        nullable part, and a CROSS-FIELD rule

// Currency is an enum value object — a part of Money, proving a value object
// nests inside a composite and still persists as its underlying scalar.
type Currency string

const (
	CurrencyBRL Currency = "BRL"
	CurrencyUSD Currency = "USD"
	CurrencyEUR Currency = "EUR"
)

func (c Currency) Value() string      { return string(c) }
func (c Currency) Values() []Currency { return []Currency{CurrencyBRL, CurrencyUSD, CurrencyEUR} }
func (c Currency) UnknownNotification() domain.Notification {
	return UnknownCurrencyNotification{}
}

// ContractCode is a raw (scalar) value object: it declares Value(), so it
// occupies exactly one column and is declared with Field(...). It is here to
// keep the contrast visible in one entity.
type ContractCode string

func (c ContractCode) Value() string { return string(c) }

func (c ContractCode) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if c == "" {
		ctx.AddNotification(fieldName, domain.RequiredFieldNotification{})
		return false
	}
	return true
}

// Money is a MANDATORY composite value object: an amount in minor units paired
// with the currency it is denominated in. Neither field means anything alone,
// which is the whole reason the concept is one value object rather than two
// columns on the entity.
type Money struct {
	Amount   int64    `labelKey:"MoneyAmountField"`
	Currency Currency `labelKey:"MoneyCurrencyField"`
}

// IsValid owns the rule. It also validates the part that is itself a value
// object: the entity's pass validates the COMPOSITE, never its interior.
func (m Money) IsValid(_ string, ctx *domain.NotificationContext) bool {
	ok := domain.ValidateEnum(m.Currency, "Currency", ctx)
	if m.Amount < 0 {
		ctx.AddNotification("Amount", NegativeAmountNotification{}, m.Amount)
		ok = false
	}
	return ok
}

// Period is an OPTIONAL composite value object (the entity holds it as a
// pointer). Its rule is a CROSS-FIELD one — the thing a single-scalar value
// object cannot express, and the reason composites exist at all.
type Period struct {
	From time.Time  `labelKey:"PeriodFromField"`
	To   *time.Time `labelKey:"PeriodToField"`
}

func (p Period) IsValid(_ string, ctx *domain.NotificationContext) bool {
	if p.To != nil && p.To.Before(p.From) {
		ctx.AddNotification("To", PeriodEndsBeforeStartNotification{})
		return false
	}
	return true
}

// Contract is the aggregate root of the family: flat (no children), so the
// suite observes the composites and nothing else.
type Contract struct {
	domain.AggregateRoot

	Code   ContractCode `labelKey:"ContractCodeField"`
	Salary Money
	Trial  *Period
}

func (c *Contract) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate,
		domain.ModeArchive, domain.ModeUnarchive, domain.ModeDelete,
	}
}

// BuildRules carries only the rules that are NOT a value object's own. Salary
// and Trial are absent on purpose: each composite's IsValid runs automatically,
// and a nil Trial is skipped entirely — absence is not a violation.
func (c *Contract) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfUpdate(func() {
		// A transition rule reading the composite off the Old() ghost — the clone
		// is a JSON round-trip, but what it hands back is the typed entity, so the
		// value object crosses it whole.
		if old := domain.Old(c); old != nil {
			if old.Salary.Currency != "" && old.Salary.Currency != c.Salary.Currency {
				r.AddNotification("Salary", CurrencyIsImmutableNotification{})
			}
		}
	})
}
