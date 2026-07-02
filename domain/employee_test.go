package domain_test

import (
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// Shared fixtures. The generic helpers (ptr, hasNotification, dumpContexts,
// validAddress, asCarrier) live in user_test.go — same package.

func validDependent() appdomain.Dependent {
	op := "Unimed"
	card := "UN-889923"
	val := time.Date(2027, 12, 31, 0, 0, 0, 0, time.UTC)
	return appdomain.Dependent{
		Name:               "Maria Silva",
		BirthDate:          time.Date(2015, 3, 10, 0, 0, 0, 0, time.UTC),
		Relationship:       "daughter",
		HealthPlanProvider: &op,
		HealthPlanCard:     &card,
		HealthPlanExpiry:   &val,
	}
}

func validJobHistory() appdomain.JobHistory {
	return appdomain.JobHistory{
		JobTitle:   "Engineer",
		Department: "Platform",
		HiredAt:    time.Date(2022, 1, 10, 0, 0, 0, 0, time.UTC),
	}
}

func validEmployee() *appdomain.Employee {
	return &appdomain.Employee{
		Name:           "Jane Doe",
		Email:          "jane@example.com",
		Phone:          ptr("14155552671"),
		Document:       "10000000001",
		EmployeeNumber: "EMP-0001",
	}
}

func buildValidEmployee(t *testing.T) *appdomain.Employee {
	t.Helper()
	f := validEmployee()
	f.SetID(domain.NewRandomID())
	f.AddAddress(validAddress(), nil)
	f.AddDependent(validDependent())
	f.AddJobHistory(validJobHistory())
	return f
}

// ─── Root rules ──────────────────────────────────────────────────────────────

func TestEmployee_BuildRules_HappyPath(t *testing.T) {
	f := validEmployee()
	f.AddAddress(validAddress(), nil)
	f.AddDependent(validDependent())
	f.AddJobHistory(validJobHistory())

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected validation to pass, got: %s", dumpContexts(ctxs))
	}
}

func TestEmployee_BuildRules_RequiredRootFields(t *testing.T) {
	cases := []struct {
		field  string
		mutate func(*appdomain.Employee)
	}{
		{"name", func(f *appdomain.Employee) { f.Name = "" }},
		{"email", func(f *appdomain.Employee) { f.Email = "" }},
		{"document", func(f *appdomain.Employee) { f.Document = "" }},
		{"employeeNumber", func(f *appdomain.Employee) { f.EmployeeNumber = "" }},
	}
	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			f := validEmployee()
			tc.mutate(f)
			ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
			if ok {
				t.Fatal("expected validation to fail")
			}
			if !hasNotification(ctxs, tc.field, "RequiredFieldNotification") {
				t.Fatalf("expected RequiredFieldNotification on %s; got %s", tc.field, dumpContexts(ctxs))
			}
		})
	}
}

func TestEmployee_BuildRules_BankFieldsOptional(t *testing.T) {
	// The whole bank facet nil = no sibling row — must validate clean.
	f := validEmployee()
	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected nil bank facet to pass, got: %s", dumpContexts(ctxs))
	}
}

func TestEmployee_DocumentImmutable_RejectsChangeOnUpdate(t *testing.T) {
	f := buildValidEmployee(t)
	apply := func(x *appdomain.Employee) error { x.Document = "99999999999"; return nil }

	_, err := domain.GetUpdatable(f, apply, nil, "GetUpdatable")
	if err == nil {
		t.Fatal("expected GetUpdatable to fail when document is changed (immutable rule)")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected NotificationCarrier error; got %v", err)
	}
	if !hasNotification(carrier.NotificationContexts(), "document", "DocumentCannotChangeNotification") {
		t.Fatalf("expected DocumentCannotChangeNotification on document; got %s",
			dumpContexts(carrier.NotificationContexts()))
	}
}

// ─── Aggregate boundary ──────────────────────────────────────────────────────

func TestEmployee_AggregateChildren_DeclaresAllThreeTypes(t *testing.T) {
	f := validEmployee()
	kinds := map[string]bool{}
	for _, c := range f.AggregateChildren() {
		switch c.(type) {
		case appdomain.Address:
			kinds["Address"] = true
		case appdomain.Dependent:
			kinds["Dependent"] = true
		case appdomain.JobHistory:
			kinds["JobHistory"] = true
		}
	}
	if len(kinds) != 3 {
		t.Fatalf("expected Address+Dependent+JobHistory declared, got %v", kinds)
	}
}

// Employee.AddAddress uses MERGE semantics (silent skip) for a duplicate
// business identity — the warm-upsert contract — unlike User.AddAddress,
// which rejects with a notification.
func TestEmployee_AddAddress_SilentlySkipsDuplicateBusinessIdentity(t *testing.T) {
	f := validEmployee()
	a := validAddress()
	dup := validAddress()
	other := "other"
	dup.Label = &other

	f.AddAddress(a, nil)
	f.AddAddress(dup, nil)

	items := domain.GetCurrentItemsOf[appdomain.Address](&f.AggregateRoot)
	if len(items) != 1 {
		t.Fatalf("expected duplicate address to be rejected, got %d items", len(items))
	}
}

func TestEmployee_MultipleChildCollections_Independent(t *testing.T) {
	f := validEmployee()
	f.AddDependent(validDependent())
	dep2 := validDependent()
	dep2.Name = "Pedro Silva"
	dep2.Relationship = "son"
	f.AddDependent(dep2)
	f.AddJobHistory(validJobHistory())

	deps := domain.GetCurrentItemsOf[appdomain.Dependent](&f.AggregateRoot)
	hists := domain.GetCurrentItemsOf[appdomain.JobHistory](&f.AggregateRoot)
	if len(deps) != 2 || len(hists) != 1 {
		t.Fatalf("expected 2 dependents + 1 job history, got %d + %d", len(deps), len(hists))
	}
}

// ─── Child rules (fire at the boundary, scoped per collection/index) ─────────

func TestDependent_BuildRules_RequiredFields(t *testing.T) {
	f := validEmployee()
	f.AddDependent(appdomain.Dependent{}) // everything missing

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail")
	}
	for _, field := range []string{"dependents[0].name", "dependents[0].birthDate", "dependents[0].relationship"} {
		if !hasNotification(ctxs, field, "RequiredFieldNotification") {
			t.Fatalf("expected RequiredFieldNotification on %s; got %s", field, dumpContexts(ctxs))
		}
	}
}

func TestDependent_BuildRules_RelationshipOutsideSet(t *testing.T) {
	f := validEmployee()
	d := validDependent()
	d.Relationship = "primo"
	f.AddDependent(d)

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail")
	}
	if !hasNotification(ctxs, "dependents[0].relationship", "InvalidRelationshipNotification") {
		t.Fatalf("expected InvalidRelationshipNotification; got %s", dumpContexts(ctxs))
	}
}

func TestDependent_BuildRules_PlanFieldsOptional(t *testing.T) {
	f := validEmployee()
	d := validDependent()
	d.HealthPlanProvider, d.HealthPlanCard, d.HealthPlanExpiry = nil, nil, nil
	f.AddDependent(d)

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected nil plan facet to pass, got: %s", dumpContexts(ctxs))
	}
}

func TestJobHistory_BuildRules_RequiredFields(t *testing.T) {
	f := validEmployee()
	f.AddJobHistory(appdomain.JobHistory{})

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail")
	}
	for _, field := range []string{"jobHistories[0].jobTitle", "jobHistories[0].department", "jobHistories[0].hiredAt"} {
		if !hasNotification(ctxs, field, "RequiredFieldNotification") {
			t.Fatalf("expected RequiredFieldNotification on %s; got %s", field, dumpContexts(ctxs))
		}
	}
}

func TestJobHistory_BuildRules_TerminatedAtBeforeHiredAt(t *testing.T) {
	f := validEmployee()
	h := validJobHistory()
	before := h.HiredAt.AddDate(-1, 0, 0)
	h.TerminatedAt = &before
	f.AddJobHistory(h)

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail")
	}
	if !hasNotification(ctxs, "jobHistories[0].terminatedAt", "TerminationBeforeHireNotification") {
		t.Fatalf("expected TerminationBeforeHireNotification; got %s", dumpContexts(ctxs))
	}
}

func TestJobHistory_BuildRules_OpenEndedPositionPasses(t *testing.T) {
	f := validEmployee()
	f.AddJobHistory(validJobHistory()) // TerminatedAt nil = current

	ok, ctxs := domain.IsValid(f, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected open-ended position to pass, got: %s", dumpContexts(ctxs))
	}
}
