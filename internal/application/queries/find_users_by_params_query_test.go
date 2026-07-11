package queries

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUsersByParamsQuery_ToCriteriaIsIdentity(t *testing.T) {
	want := fwqueries.ReadCriteria{
		Filter:          map[string]any{"name": "Jane", "email": map[string]any{"$in": []any{"a@x.com"}}},
		Limit:           20,
		Sort:            []fwqueries.SortField{{Field: "name", Desc: true}},
		IncludeArchived: true,
	}
	q := FindUsersByParamsQuery{Criteria: want}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got, _ := q.ToCriteria(ctx)

	if got.Limit != 20 || !got.IncludeArchived {
		t.Errorf("scalar fields not preserved: %+v", got)
	}
	if got.Filter["name"] != "Jane" {
		t.Errorf("filter[name] not preserved: %v", got.Filter["name"])
	}
	if len(got.Sort) != 1 || got.Sort[0].Field != "name" || !got.Sort[0].Desc {
		t.Errorf("sort not preserved: %+v", got.Sort)
	}
}

func ctxWithPermissions(perms ...string) *configuration.AppContext {
	ctx := configuration.NewAppContextWithRandomID(configuration.LangENG)
	ctx.SetIdentity(&configuration.Identity{
		Subject: "u1",
		Claims:  map[string]any{"permissions": perms},
	})
	return ctx
}

func TestFindUsersByParamsQuery_PhoneRestrictedForNonAdmin(t *testing.T) {
	got, err := FindUsersByParamsQuery{}.ToCriteria(ctxWithPermissions("users:read"))
	if err != nil {
		t.Fatalf("passive read should not 403, got %v", err)
	}
	if v, ok := got.Projection["Phone"]; !ok || v != 0 {
		t.Errorf("Phone should be excluded for a non-admin, got Projection=%v", got.Projection)
	}
}

func TestFindUsersByParamsQuery_PhoneVisibleForAdmin(t *testing.T) {
	got, err := FindUsersByParamsQuery{}.ToCriteria(ctxWithPermissions("users:admin"))
	if err != nil {
		t.Fatalf("admin read should not error, got %v", err)
	}
	if _, ok := got.Projection["Phone"]; ok {
		t.Errorf("Phone must not be restricted for an admin, got Projection=%v", got.Projection)
	}
}

func TestFindUsersByParamsQuery_PhoneVisibleWhenAuthDisabled(t *testing.T) {
	// nil Identity (auth-disabled dev) trusts everyone — Phone stays.
	got, err := FindUsersByParamsQuery{}.ToCriteria(configuration.NewAppContextWithRandomID(configuration.LangENG))
	if err != nil {
		t.Fatalf("auth-disabled read should not error, got %v", err)
	}
	if _, ok := got.Projection["Phone"]; ok {
		t.Errorf("Phone must not be restricted under auth-disabled, got Projection=%v", got.Projection)
	}
}

func TestFindUsersByParamsQuery_ActivePhoneRequestIs403ForNonAdmin(t *testing.T) {
	// ?fields=phone → Projection{Phone:1}; a non-admin actively asking for the
	// restricted field is refused with a 403.
	q := FindUsersByParamsQuery{Criteria: fwqueries.ReadCriteria{Projection: map[string]int{"Phone": 1, "Name": 1}}}
	if _, err := q.ToCriteria(ctxWithPermissions("users:read")); err == nil {
		t.Fatal("expected 403 when a non-admin actively requests Phone")
	}
}
