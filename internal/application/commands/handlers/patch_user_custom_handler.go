package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// PatchUserCustomCommandHandler is the manual PATCH-shaped handler. Identical shape to
// UpdateUserCustomCommandHandler, except it calls GetPartialUpdatable (which applies
// only non-nil fields). The framework's PartialUpdateCommandHandler is the
// generic equivalent in the canonical /users/* surface.
type PatchUserCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *PatchUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.PatchUserCustomCommand,
) (commands.UserCustomResult, error) {
	repo := h.Repo.Scope(ctx)
	user, err := repo.FindByDocument(cmd.DocumentKey)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	apply := func(u *appdomain.User) error { return cmd.ApplyPartiallyTo(ctx, u) }
	updatable, err := domain.GetPartialUpdatable(user, apply, h.Service, "GetPartialUpdatable")
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	if err := repo.Update(updatable); err != nil {
		return commands.UserCustomResult{}, err
	}
	result, err := cmd.FromEntity(ctx, user)
	if err != nil {
		return commands.UserCustomResult{}, err
	}
	return result, nil
}
