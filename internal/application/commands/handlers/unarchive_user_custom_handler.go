package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// UnarchiveUserCustomCommandHandler restores a soft-deleted user. The lookup goes through
// FindArchivedByDocument because the canonical FindByDocument filters
// deleted_at IS NULL — an archived row would surface as NotFound. Hydrating
// the archived aggregate (children included) before dispatch is what allows
// the framework's aggregate persister to cascade the unarchive to the
// addresses; without the children loaded, AllAggregateItems() returns
// nothing and the cascade SQL has no typeNames to iterate.
//
// cmd.ApplyTo runs AFTER FindArchivedByDocument and BEFORE GetUnarchivable —
// same seam for ctx → authz translation the framework's
// UnarchiveCommandHandler exposes on the canonical surface.
//
// Returns fwresults.None to match the canonical Auto handler default — the
// wire layer emits a success envelope without a `data` field, same shape
// the canonical /users/:id/unarchive returns.
type UnarchiveUserCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *UnarchiveUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.UnarchiveUserCustomCommand,
) (fwresults.None, error) {
	repo := h.Repo.Scope(ctx)
	user, err := repo.FindArchivedByDocument(cmd.DocumentKey)
	if err != nil {
		return fwresults.None{}, err
	}

	cmd.ApplyTo(ctx, user)
	unarchivable, err := domain.GetUnarchivable(user, h.Service, "GetUnarchivable")
	if err != nil {
		return fwresults.None{}, err
	}

	if err := repo.Unarchive(unarchivable); err != nil {
		return fwresults.None{}, err
	}
	return fwresults.None{}, nil
}
