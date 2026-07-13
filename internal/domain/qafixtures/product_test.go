//go:build qa

package qafixtures_test

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// The Product rules contract: the grouped-facts invariant (max 3 distinct
// active categories) consumes the ProductStats port through the injected
// ProductService — pure domain tests over a fake port, no database.

// fakeStats answers the port from a canned fact list (or error).
type fakeStats struct {
	facts []qadomain.ProductCategoryFact
	err   error
}

func (f fakeStats) ActiveCategoryFacts() ([]qadomain.ProductCategoryFact, error) {
	return f.facts, f.err
}

func factsFor(categories ...string) []qadomain.ProductCategoryFact {
	out := make([]qadomain.ProductCategoryFact, 0, len(categories))
	for i, c := range categories {
		out = append(out, qadomain.ProductCategoryFact{Category: c, Count: int64(i + 1)})
	}
	return out
}

func serviceWith(stats qadomain.ProductStats) *qadomain.ProductService {
	return &qadomain.ProductService{Stats: stats}
}

func validProduct(category string) *qadomain.Product {
	return &qadomain.Product{
		Code:       "PRD-1",
		Category:   category,
		PriceCents: 1050,
		Weight:     1.5,
	}
}

func hasNotification(ctxs []*domain.NotificationContext, wantField, wantNotifType string) bool {
	for _, ctx := range ctxs {
		for _, msg := range ctx.Messages() {
			if msg.ResolveFieldName() == wantField &&
				reflect.TypeOf(msg.Notification).Name() == wantNotifType {
				return true
			}
		}
	}
	return false
}

func dumpContexts(ctxs []*domain.NotificationContext) string {
	var out []string
	for _, ctx := range ctxs {
		for _, msg := range ctx.Messages() {
			out = append(out, msg.ResolveFieldName()+":"+reflect.TypeOf(msg.Notification).Name())
		}
	}
	return "[" + strings.Join(out, ", ") + "]"
}

func carrierOf(t *testing.T, err error) []*domain.NotificationContext {
	t.Helper()
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("error must be a NotificationCarrier; got %T: %v", err, err)
	}
	return carrier.NotificationContexts()
}

func TestProduct_Insert_NewCategoryUnderLimit_Allows(t *testing.T) {
	svc := serviceWith(fakeStats{facts: factsFor("books", "tools")})
	if _, err := domain.GetInsertable(validProduct("garden"), svc, "GetInsertable"); err != nil {
		t.Fatalf("a third distinct category must pass, got: %v", err)
	}
}

func TestProduct_Insert_FourthCategory_Rejects(t *testing.T) {
	svc := serviceWith(fakeStats{facts: factsFor("books", "tools", "garden")})
	_, err := domain.GetInsertable(validProduct("auto"), svc, "GetInsertable")
	if err == nil {
		t.Fatal("a fourth distinct category must be rejected")
	}
	ctxs := carrierOf(t, err)
	if !hasNotification(ctxs, "category", "ProductCategoryLimitNotification") {
		t.Fatalf("expected ProductCategoryLimitNotification on Category; got %s", dumpContexts(ctxs))
	}
}

func TestProduct_Insert_ExistingCategoryAtLimit_Allows(t *testing.T) {
	// The cap gates only NEW keys: at the limit, inserting into an existing
	// category is always fine.
	svc := serviceWith(fakeStats{facts: factsFor("books", "tools", "garden")})
	if _, err := domain.GetInsertable(validProduct("tools"), svc, "GetInsertable"); err != nil {
		t.Fatalf("an existing category must pass at the limit, got: %v", err)
	}
}

func TestProduct_Insert_NilService_Rejects(t *testing.T) {
	// RequiresService() true → the framework itself rejects a nil Service
	// before any rule runs.
	_, err := domain.GetInsertable(validProduct("books"), nil, "GetInsertable")
	if err == nil {
		t.Fatal("a nil Service must be rejected (RequiresService is true)")
	}
	ctxs := carrierOf(t, err)
	if !hasNotification(ctxs, "service", "ServiceIsRequiredNotification") {
		t.Fatalf("expected ServiceIsRequiredNotification; got %s", dumpContexts(ctxs))
	}
}

func TestProduct_Insert_StatsFailure_Panics(t *testing.T) {
	// A stats-backend failure is not a validation outcome — the rule panics so
	// the pipeline's single recover point renders the 500 Exception envelope
	// and the write never happens.
	svc := serviceWith(fakeStats{err: fmt.Errorf("relational backend down")})
	defer func() {
		if recover() == nil {
			t.Fatal("a stats error must panic out of BuildRules")
		}
	}()
	_, _ = domain.GetInsertable(validProduct("books"), svc, "GetInsertable")
}

func TestProduct_Insert_FieldValidations(t *testing.T) {
	svc := serviceWith(fakeStats{})
	p := &qadomain.Product{PriceCents: -1}
	_, err := domain.GetInsertable(p, svc, "GetInsertable")
	if err == nil {
		t.Fatal("empty Code/Category and a negative price must be rejected")
	}
	ctxs := carrierOf(t, err)
	for field, notif := range map[string]string{
		"code":       "RequiredFieldNotification",
		"category":   "RequiredFieldNotification",
		"priceCents": "SchemaViolationNotification",
	} {
		if !hasNotification(ctxs, field, notif) {
			t.Errorf("expected %s on %s; got %s", notif, field, dumpContexts(ctxs))
		}
	}
}
