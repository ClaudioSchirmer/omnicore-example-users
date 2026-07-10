package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// ArchiveUserCustomCommandHandler is the manual soft-delete handler. State transition,
// not field mutation — there is no apply closure; cmd.ApplyTo lands AFTER
// FindByDocument and BEFORE GetArchivable as the seam for future ctx → authz
// translation, then GetArchivable snapshots the entity (so audit logs
// `previous`) and validates that ModeArchive is declared. Orchestrator.Archive
// cascades to addresses transparently because *User implements
// AggregateRootProvider — same path the framework's ArchiveCommandHandler
// takes.
//
// Returns fwresults.None to match the canonical Auto handler default — the
// wire layer emits a success envelope without a `data` field. The manual
// showcase no longer carries a full body on state-transition verbs; its
// value-add is the manual orchestration written out, not a divergent
// response shape.
type ArchiveUserCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *ArchiveUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.ArchiveUserCustomCommand,
) (fwresults.None, error) {
	repo := h.Repo.Scope(ctx)
	user, err := repo.FindByDocument(cmd.DocumentKey)
	if err != nil {
		return fwresults.None{}, err
	}

	cmd.ApplyTo(ctx, user)
	archivable, err := domain.GetArchivable(user, h.Service, "GetArchivable")
	if err != nil {
		return fwresults.None{}, err
	}

	if err := repo.Archive(archivable); err != nil {
		return fwresults.None{}, err
	}
	return fwresults.None{}, nil
}
