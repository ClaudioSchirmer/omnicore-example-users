package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"
)

func TestFindPersonsByParamsRequest_ToQueryReturnsCriteria(t *testing.T) {
	crit := fwqueries.ReadCriteria{
		Filter: map[string]any{"User.UserName": "ana"},
		Limit:  5,
	}
	q := FindPersonsByParamsRequest{}.ToQuery(crit)
	if q == nil {
		t.Fatal("expected non-nil Query")
	}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got, _ := q.ToCriteria(ctx)
	if got.Filter["User.UserName"] != "ana" || got.Limit != 5 {
		t.Errorf("criteria not preserved, got %+v", got)
	}
}

func TestFindPersonByIDRequest_ToQuery(t *testing.T) {
	arch := true
	q := FindPersonByIDRequest{IncludeArchived: &arch}.ToQuery()
	if !q.IncludeArchived {
		t.Error("IncludeArchived=true must propagate")
	}
	if q2 := (FindPersonByIDRequest{}).ToQuery(); q2.IncludeArchived {
		t.Error("nil IncludeArchived must default to false")
	}
}

// readerGoPersonDoc mirrors what MongoViewReader hands the projector for a
// two-role person: root fields Go-keyed, Addresses at the root, and one
// Go-keyed sub-map per role segment ("User"/"Employee" — the segments the
// SharedBaseView derives from the role Go types), the employee carrying its
// bank sibling flat and its child collections nested.
func readerGoPersonDoc() map[string]any {
	return map[string]any{
		"ID":       "person-1",
		"Name":     "Ana Souza",
		"Email":    "ana@example.com",
		"Document": "70000000001",
		"Addresses": []any{
			map[string]any{"ID": "addr-1", "Street": "Rua A", "Number": "1",
				"Neighborhood": "Centro", "City": "POA", "State": "RS",
				"ZipCode": "90000000", "Country": "BR"},
		},
		"User": map[string]any{
			"ID": "person-1", "UserName": "ana", "EmailNotification": true,
		},
		"Employee": map[string]any{
			"ID": "person-1", "EmployeeNumber": "EMP-1", "Bank": "260",
			"Dependents": []any{
				map[string]any{"ID": "dep-1", "Name": "Rita",
					"Relationship": "daughter", "HealthPlanProvider": "Unimed"},
			},
			"JobHistories": []any{
				map[string]any{"ID": "job-1", "JobTitle": "Engineer", "Department": "Platform"},
			},
		},
	}
}

func TestFindPersonsByParamsResponse_AutoFromDoc_RoleSegments(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindPersonsByParamsResponse](readerGoPersonDoc())
	if strDeref(got.Name) != "Ana Souza" || strDeref(got.Document) != "70000000001" {
		t.Errorf("root fields: got %+v", got)
	}
	if len(got.Addresses) != 1 || strDeref(got.Addresses[0].City) != "POA" {
		t.Errorf("root addresses: got %+v", got.Addresses)
	}
	if got.User == nil || strDeref(got.User.UserName) != "ana" {
		t.Fatalf("user segment: got %+v", got.User)
	}
	if got.User.EmailNotification == nil || !*got.User.EmailNotification {
		t.Errorf("user sibling flag: got %+v", got.User.EmailNotification)
	}
	if got.Employee == nil || strDeref(got.Employee.EmployeeNumber) != "EMP-1" {
		t.Fatalf("employee segment: got %+v", got.Employee)
	}
	if strDeref(got.Employee.Bank) != "260" {
		t.Errorf("bank sibling flat in the segment: got %q", strDeref(got.Employee.Bank))
	}
	if len(got.Employee.Dependents) != 1 || strDeref(got.Employee.Dependents[0].HealthPlanProvider) != "Unimed" {
		t.Errorf("dependents (with plan sibling) inside the segment: got %+v", got.Employee.Dependents)
	}
	if len(got.Employee.JobHistories) != 1 || strDeref(got.Employee.JobHistories[0].JobTitle) != "Engineer" {
		t.Errorf("jobHistories inside the segment: got %+v", got.Employee.JobHistories)
	}
}

func TestFindPersonsByParamsResponse_AutoFromDoc_AbsentRoleIsNil(t *testing.T) {
	doc := readerGoPersonDoc()
	delete(doc, "Employee") // a user-only person: the reader dropped the null segment
	got := fwresponses.AutoFromDoc[FindPersonsByParamsResponse](doc)
	if got.Employee != nil {
		t.Errorf("absent role must project as nil (omitted on the wire), got %+v", got.Employee)
	}
	if got.User == nil {
		t.Error("present role must still project")
	}
}

func TestFindPersonByIDResponse_AutoFromDoc(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindPersonByIDResponse](readerGoPersonDoc())
	if got.Name != "Ana Souza" || got.Document != "70000000001" {
		t.Errorf("root fields: got %+v", got)
	}
	if got.User == nil || strDeref(got.User.UserName) != "ana" {
		t.Errorf("user segment: got %+v", got.User)
	}
	if got.Employee == nil || len(got.Employee.Dependents) != 1 {
		t.Errorf("employee segment: got %+v", got.Employee)
	}
}
