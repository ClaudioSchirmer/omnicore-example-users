package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// PatchUserCustomCommandHandler is the manual PATCH-shaped handler. Identical shape to
// UpdateUserCustomCommandHandler, except it calls GetPartialUpdatable (which applies
// only non-nil fields). The framework's PartialUpdateCommandHandler is the
// generic equivalent in the canonical /users/* surface.
type PatchUserCustomCommandHandler struct {
	Repo    UserCustomRepository
	Service domain.Service
}

func (h *PatchUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.PatchUserCustomCommand,
) (commands.UserCustomResult, error) {
	user, err := h.Repo.FindByEmail(cmd.EmailKey)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	apply := func(u *appdomain.User) { cmd.ApplyPartiallyTo(ctx, u) }
	updatable, err := domain.GetPartialUpdatable(user, apply, h.Service, "GetPartialUpdatable")
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	if err := h.Repo.Update(ctx, updatable); err != nil {
		return commands.UserCustomResult{}, err
	}
	return cmd.FromEntity(ctx, user), nil
}
