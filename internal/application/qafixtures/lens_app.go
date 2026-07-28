//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// Commands + queries for the materialized view-on-view family. The full write
// vocabulary is here on BOTH roots because the suite drives each verb against
// each hop of the chain: insert, update (including the FK moves — repointing a
// part at another gadget, or moving it to another kit), archive, unarchive and
// hard delete.

// ─── LensBrand (the deepest root — the one with an update verb) ──────────────

type InsertLensBrandCommand struct {
	pipeline.CommandWithBodyBase
	Name string
}

func (c *InsertLensBrandCommand) ToEntity(_ *configuration.AppContext) (*qadomain.LensBrand, error) {
	return &qadomain.LensBrand{Name: c.Name}, nil
}

func (c *InsertLensBrandCommand) FromEntity(_ *configuration.AppContext, b *qadomain.LensBrand) (LensBrandResult, error) {
	return LensBrandResult{ID: *b.GetID(), Name: b.Name}, nil
}

type LensBrandResult struct {
	ID   domain.ID
	Name string
}

var _ pipeline.InsertCommand[*qadomain.LensBrand, LensBrandResult] = (*InsertLensBrandCommand)(nil)

type UpdateLensBrandCommand struct {
	pipeline.CommandWithBodyIDBase
	Name string
}

func (c *UpdateLensBrandCommand) ApplyTo(_ *configuration.AppContext, b *qadomain.LensBrand) error {
	b.Name = c.Name
	return nil
}

func (c *UpdateLensBrandCommand) FromEntity(_ *configuration.AppContext, b *qadomain.LensBrand) (LensBrandResult, error) {
	return LensBrandResult{ID: *b.GetID(), Name: b.Name}, nil
}

type ArchiveLensBrandCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveLensBrandCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensBrand) error {
	return nil
}
func (*ArchiveLensBrandCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensBrand) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveLensBrandCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveLensBrandCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensBrand) error {
	return nil
}
func (*UnarchiveLensBrandCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensBrand) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type DeleteLensBrandCommand struct{ pipeline.CommandByIDBase }

func (*DeleteLensBrandCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensBrand) error {
	return nil
}
func (*DeleteLensBrandCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensBrand) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── LensKit (the outer root) ────────────────────────────────────────────────

type InsertLensKitCommand struct {
	pipeline.CommandWithBodyBase
	Name string
}

func (c *InsertLensKitCommand) ToEntity(_ *configuration.AppContext) (*qadomain.LensKit, error) {
	return &qadomain.LensKit{Name: c.Name}, nil
}

func (c *InsertLensKitCommand) FromEntity(_ *configuration.AppContext, k *qadomain.LensKit) (LensKitResult, error) {
	return LensKitResult{ID: *k.GetID(), Name: k.Name}, nil
}

type LensKitResult struct {
	ID   domain.ID
	Name string
}

var _ pipeline.InsertCommand[*qadomain.LensKit, LensKitResult] = (*InsertLensKitCommand)(nil)

type UpdateLensKitCommand struct {
	pipeline.CommandWithBodyIDBase
	Name string
}

func (c *UpdateLensKitCommand) ApplyTo(_ *configuration.AppContext, k *qadomain.LensKit) error {
	k.Name = c.Name
	return nil
}

func (c *UpdateLensKitCommand) FromEntity(_ *configuration.AppContext, k *qadomain.LensKit) (LensKitResult, error) {
	return LensKitResult{ID: *k.GetID(), Name: k.Name}, nil
}

type ArchiveLensKitCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveLensKitCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensKit) error { return nil }
func (*ArchiveLensKitCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensKit) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveLensKitCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveLensKitCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensKit) error {
	return nil
}
func (*UnarchiveLensKitCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensKit) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type DeleteLensKitCommand struct{ pipeline.CommandByIDBase }

func (*DeleteLensKitCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensKit) error { return nil }
func (*DeleteLensKitCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensKit) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── LensPart (the middle root — both FKs are updatable) ─────────────────────

type InsertLensPartCommand struct {
	pipeline.CommandWithBodyBase
	KitID    *string
	GadgetID *string
	BrandID  *string
	Label    string
	Slot     int
}

func (c *InsertLensPartCommand) ToEntity(_ *configuration.AppContext) (*qadomain.LensPart, error) {
	return &qadomain.LensPart{KitID: c.KitID, GadgetID: c.GadgetID, BrandID: c.BrandID, Label: c.Label, Slot: c.Slot}, nil
}

func (c *InsertLensPartCommand) FromEntity(_ *configuration.AppContext, p *qadomain.LensPart) (LensPartResult, error) {
	return LensPartResult{ID: *p.GetID(), Label: p.Label, Slot: p.Slot}, nil
}

type LensPartResult struct {
	ID    domain.ID
	Label string
	Slot  int
}

var _ pipeline.InsertCommand[*qadomain.LensPart, LensPartResult] = (*InsertLensPartCommand)(nil)

// UpdateLensPartCommand rewrites the label, the slot and BOTH foreign keys —
// the two moves the materialized segments must follow: repointing gadget_id
// (the 1:1 segment must re-resolve, which only the post-write repair can do,
// since nothing changed on the gadget's side) and repointing kit_id (the
// element must leave one kit's array and enter another's).
type UpdateLensPartCommand struct {
	pipeline.CommandWithBodyIDBase
	KitID    *string
	GadgetID *string
	BrandID  *string
	Label    string
	Slot     int
}

func (c *UpdateLensPartCommand) ApplyTo(_ *configuration.AppContext, p *qadomain.LensPart) error {
	p.KitID = c.KitID
	p.GadgetID = c.GadgetID
	p.BrandID = c.BrandID
	p.Label = c.Label
	p.Slot = c.Slot
	return nil
}

func (c *UpdateLensPartCommand) FromEntity(_ *configuration.AppContext, p *qadomain.LensPart) (LensPartResult, error) {
	return LensPartResult{ID: *p.GetID(), Label: p.Label, Slot: p.Slot}, nil
}

type ArchiveLensPartCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveLensPartCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensPart) error {
	return nil
}
func (*ArchiveLensPartCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensPart) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveLensPartCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveLensPartCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensPart) error {
	return nil
}
func (*UnarchiveLensPartCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensPart) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type DeleteLensPartCommand struct{ pipeline.CommandByIDBase }

func (*DeleteLensPartCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.LensPart) error {
	return nil
}
func (*DeleteLensPartCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.LensPart) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── Queries (one by-id + one paged list per hop) ────────────────────────────

type FindLensKitByIDQuery struct {
	fwqueries.QueryByIDBase
	IncludeArchived bool
}

func (q FindLensKitByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}
func (q FindLensKitByIDQuery) ContextName() string { return "LensKit" }

type FindLensKitsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindLensKitsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

type FindLensBrandsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindLensBrandsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

type FindLensPartByIDQuery struct {
	fwqueries.QueryByIDBase
	IncludeArchived bool
}

func (q FindLensPartByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}
func (q FindLensPartByIDQuery) ContextName() string { return "LensPart" }

type FindLensPartsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindLensPartsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
