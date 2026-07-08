package commands

import (
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

func fptr(s string) *string { return &s }

func tptr(t time.Time) *time.Time { return &t }

func TestInsertEmployeeCommand_ApplyTo_CopiesAllFacets(t *testing.T) {
	adm := time.Date(2022, 1, 10, 0, 0, 0, 0, time.UTC)
	nasc := time.Date(2015, 3, 10, 0, 0, 0, 0, time.UTC)
	cmd := InsertEmployeeCommand{
		Name:           "Jane Doe",
		Email:          "jane@example.com",
		Phone:          fptr("14155552671"),
		Document:       "10000000001",
		EmployeeNumber: "EMP-0001",
		Bank:           fptr("260"),
		Branch:         fptr("0001"),
		Account:        fptr("1234567-8"),
		Pix:            fptr("jane@example.com"),
		Addresses: []dtos.AddressInput{{
			Street: "Main St", Number: "1", Neighborhood: "Centro",
			City: "Recife", State: "PE", ZipCode: "50000-000", Country: "BR",
		}},
		Dependents: []dtos.DependentInput{{
			Name: "Maria", BirthDate: nasc, Relationship: "daughter",
			HealthPlanProvider: fptr("Unimed"),
		}},
		JobHistories: []dtos.JobHistoryInput{{
			JobTitle: "Engineer", Department: "Platform", HiredAt: adm,
		}},
	}

	f := &appdomain.Employee{}
	if err := cmd.ApplyTo(nil, f); err != nil {
		t.Fatalf("ApplyTo returned error: %v", err)
	}
	if f.Name != "Jane Doe" || f.Document != "10000000001" || f.EmployeeNumber != "EMP-0001" {
		t.Fatalf("root fields not applied: %+v", f)
	}
	if f.Bank == nil || *f.Bank != "260" || f.Pix == nil || *f.Pix != "jane@example.com" {
		t.Fatalf("bank sibling fields not applied: %+v", f)
	}
	if len(domain.GetCurrentItemsOf[appdomain.Address](&f.AggregateRoot)) != 1 {
		t.Fatal("address child not attached")
	}
	deps := domain.GetCurrentItemsOf[appdomain.Dependent](&f.AggregateRoot)
	if len(deps) != 1 || deps[0].HealthPlanProvider == nil || *deps[0].HealthPlanProvider != "Unimed" {
		t.Fatalf("dependent (with plan sibling) not attached: %+v", deps)
	}
	if len(domain.GetCurrentItemsOf[appdomain.JobHistory](&f.AggregateRoot)) != 1 {
		t.Fatal("job-history child not attached")
	}
}

func TestInsertEmployeeCommand_FromEntity_RoundTrips(t *testing.T) {
	f := &appdomain.Employee{
		Name: "Jane", Email: "j@e.com", Document: "10000000001",
		EmployeeNumber: "EMP-0001", Bank: fptr("260"),
	}
	f.SetID(domain.NewRandomID())

	res, err := InsertEmployeeCommand{}.FromEntity(nil, f)
	if err != nil {
		t.Fatalf("FromEntity returned error: %v", err)
	}
	if res.ID != *f.GetID() || res.EmployeeNumber != "EMP-0001" || res.Bank == nil || *res.Bank != "260" {
		t.Fatalf("result mismatch: %+v", res)
	}
	if res.Phone != nil || res.Branch != nil {
		t.Fatalf("nil facets must stay nil: %+v", res)
	}
}

func TestUpdateEmployeeCommand_ApplyTo_ReplacesCollections(t *testing.T) {
	f := &appdomain.Employee{
		Name: "Old", Email: "old@e.com", Document: "10000000001", EmployeeNumber: "OLD",
	}
	f.AddDependent(appdomain.Dependent{Name: "ToBeReplaced",
		BirthDate: time.Now(), Relationship: "son"})

	cmd := UpdateEmployeeCommand{
		Name: "New", Email: "new@e.com", EmployeeNumber: "NEW",
		Dependents: []dtos.DependentInput{
			{Name: "A", BirthDate: time.Now(), Relationship: "daughter"},
			{Name: "B", BirthDate: time.Now(), Relationship: "son"},
		},
	}
	if err := cmd.ApplyTo(nil, f); err != nil {
		t.Fatalf("ApplyTo returned error: %v", err)
	}
	deps := domain.GetCurrentItemsOf[appdomain.Dependent](&f.AggregateRoot)
	if len(deps) != 2 {
		t.Fatalf("expected replaced collection of 2, got %d", len(deps))
	}
	// PUT with all-nil bank facet must clear the sibling fields (row removal).
	if f.Bank != nil || f.Branch != nil || f.Account != nil || f.Pix != nil {
		t.Fatalf("bank facet must be nil after a PUT omitting it: %+v", f)
	}
}

func TestPatchEmployeeCommand_ApplyPartiallyTo_TriState(t *testing.T) {
	f := &appdomain.Employee{
		Name: "Jane", Email: "j@e.com", Document: "10000000001",
		EmployeeNumber: "EMP-0001", Bank: fptr("260"), Account: fptr("1234567-8"),
	}
	cmd := &PatchEmployeeCommand{
		Name: fptr("Janet"),
		Bank: fptr("341"),
	}
	if err := cmd.ApplyPartiallyTo(nil, f); err != nil {
		t.Fatalf("ApplyPartiallyTo returned error: %v", err)
	}
	if f.Name != "Janet" {
		t.Fatalf("sent field not applied: %s", f.Name)
	}
	if f.Email != "j@e.com" || f.EmployeeNumber != "EMP-0001" {
		t.Fatalf("absent fields must keep current values: %+v", f)
	}
	if f.Bank == nil || *f.Bank != "341" {
		t.Fatalf("sent sibling field not applied: %v", f.Bank)
	}
	if f.Account == nil || *f.Account != "1234567-8" {
		t.Fatalf("absent sibling field must keep current value: %v", f.Account)
	}
}

func TestEmployeeBodylessCommands_FromEntityNone(t *testing.T) {
	f := &appdomain.Employee{}
	if _, err := (&ArchiveEmployeeCommand{}).FromEntity(nil, f); err != nil {
		t.Fatalf("archive FromEntity: %v", err)
	}
	if _, err := (&UnarchiveEmployeeCommand{}).FromEntity(nil, f); err != nil {
		t.Fatalf("unarchive FromEntity: %v", err)
	}
	if _, err := (&DeleteEmployeeCommand{}).FromEntity(nil, f); err != nil {
		t.Fatalf("delete FromEntity: %v", err)
	}
	_ = tptr(time.Now()) // keep helper referenced for future date-field tests
}
