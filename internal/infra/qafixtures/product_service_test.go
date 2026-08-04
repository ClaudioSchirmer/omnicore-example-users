//go:build qa

package qafixtures

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ProductServiceImpl is the real domain.Service Product.BuildRules consumes.
// These tests prove — on the production type, through the framework's own
// persistence.ScopeService — that the request ctx reaches the impl (so
// ActiveCategoryFacts queries under the request deadline/trace, not
// context.Background()), and that scoping never mutates the wired singleton.

func TestProductServiceImpl_ImplementsServiceAndProvider(t *testing.T) {
	var _ domain.Service = (*ProductServiceImpl)(nil)
	var _ qadomain.ProductService = (*ProductServiceImpl)(nil)
	var _ persistence.ScopedServiceProvider = (*ProductServiceImpl)(nil)
}

func TestProductServiceImpl_ScopeServiceBindsRequestCtx(t *testing.T) {
	// The wired singleton (as bootstrap builds it) carries no ctx.
	singleton := NewProductService(nil)
	if singleton.ctx != nil {
		t.Fatal("a freshly wired service must have a nil ctx (singleton)")
	}

	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)

	// Exactly what the Auto handler does before BuildRules.
	scoped := persistence.ScopeService(singleton, ctx)

	got, ok := scoped.(*ProductServiceImpl)
	if !ok {
		t.Fatalf("ScopeService returned %T, want *ProductServiceImpl", scoped)
	}
	if got == singleton {
		t.Error("ScopeService must return a per-request VIEW, not the singleton")
	}
	if got.ctx != ctx {
		t.Errorf("the scoped service did not carry the request ctx; got %v, want %v", got.ctx, ctx)
	}
	if got.repo != singleton.repo {
		t.Error("the shallow copy must keep the same repo/loader as the singleton")
	}
	if singleton.ctx != nil {
		t.Error("ScopeService must NOT mutate the wired singleton (concurrent-request safety)")
	}
}
