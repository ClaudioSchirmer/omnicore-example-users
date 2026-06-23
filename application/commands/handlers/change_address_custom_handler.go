package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ChangeAddressCustomCommandHandler is the manual showcase twin of the
// canonical UpdateCommandHandler[*User, *ChangeAddressCommand, …]. Same
// lifecycle: load → snapshot via domain.Old (captured inside GetUpdatable)
// → apply the command → validate → persist via Orchestrator.Update. The
// only step that diverges is FindByEmail in place of FindByID — same
// reason the other manual update twins (UpdateUserCustomCommandHandler,
// PatchUserCustomCommandHandler) keep their hand-rolled chain.
//
// Returns a UserCustomResult snapshot so the wire layer never touches the
// domain entity directly — the same Result type Insert/Update/Patch use,
// reused for this fourth body-emitting handler.
type ChangeAddressCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *ChangeAddressCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.ChangeAddressCustomCommand,
) (commands.UserCustomResult, error) {
	repo := h.Repo.Scope(ctx)
	user, err := repo.FindByEmail(cmd.EmailKey)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	apply := func(u *appdomain.User) error { return cmd.ApplyTo(ctx, u) }
	updatable, err := domain.GetUpdatable(user, apply, h.Service, "GetUpdatable")
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
