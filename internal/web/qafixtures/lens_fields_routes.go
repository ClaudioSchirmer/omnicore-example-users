//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// Read-only wire surface of the JoinView FIELDS family. Writes flow through the
// existing /qa/lens-* routes; these three groups only READ the additional
// projections, so the family adds endpoints without touching any existing DTO.

// The two parts routes carry DELIBERATELY DIFFERENT DTOs, each MIRRORING its
// view's cut — the layered read-side contract: the wire allowlist is the
// DTO's (an undeclared token is 400 at the membrane), and the storage never
// carries the capped column anyway. A forever consumer therefore does not even
// declare brand.deletedAt; the lifecycle consumer does, and there it is a real
// query/projection.

// LensFieldsForeverBrandFilter mirrors Fields("Name"): no deletedAt leaf, so
// ?brand.deletedAt.* is rejected 400 at the wire — the DTO is the cut's mirror.
type LensFieldsForeverBrandFilter struct {
	Name *string `query:"name" filter:"eq,contains"`
}

// LensFieldsLifecycleBrandFilter mirrors Fields("Name","DeletedAt"): the same
// token is a declared, real query here.
type LensFieldsLifecycleBrandFilter struct {
	Name      *string `query:"name"      filter:"eq,contains"`
	DeletedAt *string `query:"deletedAt" filter:"eq,ne"`
}

type FindLensFieldsForeverRequest struct {
	Label   *string `query:"label"   filter:"eq,contains"`
	BrandID *string `query:"brandId" filter:"eq"`

	Brand LensFieldsForeverBrandFilter `query:"brand"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensFieldsForeverRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensPartsQuery {
	return &appqa.FindLensPartsQuery{Criteria: criteria}
}

type FindLensFieldsLifecycleRequest struct {
	Label   *string `query:"label"   filter:"eq,contains"`
	BrandID *string `query:"brandId" filter:"eq"`

	Brand LensFieldsLifecycleBrandFilter `query:"brand"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensFieldsLifecycleRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensPartsQuery {
	return &appqa.FindLensPartsQuery{Criteria: criteria}
}

// LensFieldsForeverBrandOutput mirrors the forever cut — no DeletedAt field,
// so ?fields=brand.deletedAt is 400 at the projection allowlist too.
type LensFieldsForeverBrandOutput struct {
	ID   *string `json:"id,omitempty"`
	Name *string `json:"name,omitempty"`
}

// LensFieldsBrandOutput is the lifecycle segment: DeletedAt declared so the
// stamp SHOWS under ?includeArchived.
type LensFieldsBrandOutput struct {
	ID        *string `json:"id,omitempty"`
	Name      *string `json:"name,omitempty"`
	DeletedAt *string `json:"deletedAt,omitempty"`
}

type FindLensFieldsForeverResponse struct {
	ID      *string                       `json:"id,omitempty"`
	Label   *string                       `json:"label,omitempty"`
	Slot    *int                          `json:"slot,omitempty"`
	BrandID *string                       `json:"brandId,omitempty"`
	Brand   *LensFieldsForeverBrandOutput `json:"brand,omitempty"`
}

type FindLensFieldsPartsResponse struct {
	ID      *string                `json:"id,omitempty"`
	Label   *string                `json:"label,omitempty"`
	Slot    *int                   `json:"slot,omitempty"`
	BrandID *string                `json:"brandId,omitempty"`
	Brand   *LensFieldsBrandOutput `json:"brand,omitempty"`
}

// ─── kits: the 1:N capped elements ───────────────────────────────────────────

type FindLensFieldsKitsRequest struct {
	Name *string `query:"name" filter:"eq,contains"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensFieldsKitsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensKitsQuery {
	return &appqa.FindLensKitsQuery{Criteria: criteria}
}

// LensFieldsPartElementOutput is one capped element of the kits view's 1:N
// segment: Label + Slot + the ADMITTED Brand segment. There is deliberately NO
// Gadget field — that segment is cut by the allowlist and never materializes.
type LensFieldsPartElementOutput struct {
	ID    *string                `json:"id,omitempty"`
	Label *string                `json:"label,omitempty"`
	Slot  *int                   `json:"slot,omitempty"`
	Brand *LensFieldsBrandOutput `json:"brand,omitempty"`
}

type FindLensFieldsKitsResponse struct {
	ID    *string                       `json:"id,omitempty"`
	Name  *string                       `json:"name,omitempty"`
	Parts []LensFieldsPartElementOutput `json:"parts,omitempty"`
}

// MountLensFields registers the three read groups, one per projection.
func MountLensFields(app *fiber.App, foreverView, lifecycleView, kitsView string, d bootstrap.Deps) {
	tags := []string{"QA Lens Fields (JoinView allowlist)"}

	gf := app.Group("/qa/lens-fields-forever")
	foreverDesc := "The leg lists only \"Name\": the segment stores the brand's name (plus identity) and nothing else. " +
		"\"DeletedAt\" is NOT listed, so the segment has no archived rule by declaration — the archived brand " +
		"keeps its name here forever and keeps receiving renames through the ripple. The DTO mirrors the cut: " +
		"brand.deletedAt is not declared, so the token is 400 at the wire."
	fListH, fListSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensFieldsForeverRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsForeverResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensPartsQuery]{Reader: d.ViewReader, View: foreverView})
	fwopenapi.Mount(d.OpenAPIRegistry, gf, fiber.MethodGet, "/", fListH, fListSpec,
		fwopenapi.Doc{Summary: "Parts with the brand capped to Fields(\"Name\") — no archive rule", Description: foreverDesc, Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))
	fByIDH, fByIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensPartByIDRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsForeverResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensPartByIDQuery]{Reader: d.ViewReader, View: foreverView})
	fwopenapi.Mount(d.OpenAPIRegistry, gf, fiber.MethodGet, "/:id", fByIDH, fByIDSpec,
		fwopenapi.Doc{Summary: "Part by id, brand capped — no archive rule", Description: foreverDesc, Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))

	gl := app.Group("/qa/lens-fields-lifecycle")
	lifecycleDesc := "Same source, same cut, plus \"DeletedAt\": the segment follows the brand's archive — hidden on " +
		"default reads, revealed by ?includeArchived=true. The DTO declares brand.deletedAt, so here the token is a " +
		"real query. The pair of routes is the archive switch made observable."
	lListH, lListSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensFieldsLifecycleRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsPartsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensPartsQuery]{Reader: d.ViewReader, View: lifecycleView})
	fwopenapi.Mount(d.OpenAPIRegistry, gl, fiber.MethodGet, "/", lListH, lListSpec,
		fwopenapi.Doc{Summary: "Parts with the brand capped to Fields(\"Name\", \"DeletedAt\") — follows the archive", Description: lifecycleDesc, Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))
	lByIDH, lByIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensPartByIDRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsPartsResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensPartByIDQuery]{Reader: d.ViewReader, View: lifecycleView})
	fwopenapi.Mount(d.OpenAPIRegistry, gl, fiber.MethodGet, "/:id", lByIDH, lByIDSpec,
		fwopenapi.Doc{Summary: "Part by id, brand capped — follows the archive", Description: lifecycleDesc, Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))

	g := app.Group("/qa/lens-fields-kits")
	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensFieldsKitsRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsKitsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensKitsQuery]{Reader: d.ViewReader, View: kitsView})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/", listH, listSpec,
		fwopenapi.Doc{
			Summary: "Kits whose 1:N parts are capped to Fields(\"Label\", \"Slot\", \"Brand\")",
			Description: "Each element stores label + slot + the Brand segment ADMITTED WHOLE; the parts view's " +
				"Gadget segment and remaining columns are cut. Slot is the declared order, kit_id the forced join column.",
			Tags: tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))
	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensKitByIDRequest{},
		fwresponses.AutoFromDoc[FindLensFieldsKitsResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensKitByIDQuery]{Reader: d.ViewReader, View: kitsView})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id", byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Kit by id, parts capped by the leg's Fields",
			Description: "Same projection as the list — element identity and order are stored, the cut is the leg's.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))
}
