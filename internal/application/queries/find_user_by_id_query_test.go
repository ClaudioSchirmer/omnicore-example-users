package queries

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
)

func TestFindUserByIDQuery_ToCriteria_IncludeArchivedFalseByDefault(t *testing.T) {
	q := FindUserByIDQuery{}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected zero-value IncludeArchived to yield IncludeArchived=false")
	}
}

func TestFindUserByIDQuery_ToCriteria_IncludeArchivedFlagPropagates(t *testing.T) {
	q := FindUserByIDQuery{IncludeArchived: true}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if !crit.IncludeArchived {
		t.Error("expected IncludeArchived=true to set IncludeArchived=true")
	}
}

func TestFindUserByIDQuery_SetPathIDRoundtrip(t *testing.T) {
	q := &FindUserByIDQuery{}
	q.SetPathID("abc")
	if got := q.PathID().Value(); got != "abc" {
		t.Errorf("expected GetID()='abc', got %q", got)
	}
}

func TestFindUserByIDQuery_ContextNameIsUser(t *testing.T) {
	if got := (FindUserByIDQuery{}).ContextName(); got != "User" {
		t.Errorf("expected ContextName()=\"User\", got %q", got)
	}
}
