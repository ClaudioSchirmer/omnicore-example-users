package dtos

import (
	"testing"
	"time"
)

func TestDependentInput_ToDependent_AllFieldsCopied(t *testing.T) {
	op, card := "Unimed", "UN-1"
	val := time.Date(2027, 12, 31, 0, 0, 0, 0, time.UTC)
	in := DependentInput{
		Name:               "Maria",
		BirthDate:          time.Date(2015, 3, 10, 0, 0, 0, 0, time.UTC),
		Relationship:       "daughter",
		HealthPlanProvider: &op,
		HealthPlanCard:     &card,
		HealthPlanExpiry:   &val,
	}
	got := in.ToDependent()
	if got.Name != "Maria" || got.Relationship != "daughter" || !got.BirthDate.Equal(in.BirthDate) {
		t.Fatalf("required fields mismatch: %+v", got)
	}
	if got.HealthPlanProvider == nil || *got.HealthPlanProvider != "Unimed" ||
		got.HealthPlanCard == nil || *got.HealthPlanCard != "UN-1" ||
		got.HealthPlanExpiry == nil || !got.HealthPlanExpiry.Equal(val) {
		t.Fatalf("plan sibling fields mismatch: %+v", got)
	}
}

func TestDependentInput_ToDependent_NilPlanPreserved(t *testing.T) {
	in := DependentInput{Name: "X", BirthDate: time.Now(), Relationship: "son"}
	got := in.ToDependent()
	if got.HealthPlanProvider != nil || got.HealthPlanCard != nil || got.HealthPlanExpiry != nil {
		t.Fatalf("nil plan facet must stay nil: %+v", got)
	}
}

func TestJobHistoryInput_ToJobHistory_Copied(t *testing.T) {
	des := time.Date(2024, 6, 30, 0, 0, 0, 0, time.UTC)
	in := JobHistoryInput{
		JobTitle:     "Engineer",
		Department:   "Platform",
		HiredAt:      time.Date(2022, 1, 10, 0, 0, 0, 0, time.UTC),
		TerminatedAt: &des,
	}
	got := in.ToJobHistory()
	if got.JobTitle != "Engineer" || got.Department != "Platform" || !got.HiredAt.Equal(in.HiredAt) {
		t.Fatalf("fields mismatch: %+v", got)
	}
	if got.TerminatedAt == nil || !got.TerminatedAt.Equal(des) {
		t.Fatalf("terminatedAt mismatch: %v", got.TerminatedAt)
	}
}

func TestJobHistoryInput_ToJobHistory_NilTerminatedAt(t *testing.T) {
	in := JobHistoryInput{JobTitle: "X", Department: "Y", HiredAt: time.Now()}
	if got := in.ToJobHistory(); got.TerminatedAt != nil {
		t.Fatalf("nil terminatedAt must stay nil: %v", got.TerminatedAt)
	}
}
