package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UpdateUserCustomCommandHandler is the manual PUT-shaped handler. Same
// lifecycle as the framework's UpdateCommandHandler — load the persisted
// aggregate, snapshot it for domain.Old before mutation, apply the command,
// validate via GetUpdatable, and delegate the write to the
// persistence.Writer port — except the load step uses FindByEmail because
// /:email is the path identifier. Returns a commands.UserCustomResult
// snapshot so the wire layer never touches the domain entity directly.
type UpdateUserCustomCommandHandler struct {
	Repo    UserCustomRepository
	Service domain.Service
}

func (h *UpdateUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.UpdateUserCustomCommand,
) (commands.UserCustomResult, error) {
	user, err := h.Repo.FindByEmail(cmd.EmailKey)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	apply := func(u *appdomain.User) { cmd.ApplyTo(ctx, u) }
	updatable, err := domain.GetUpdatable(user, apply, h.Service, "GetUpdatable")
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	if err := h.Repo.Update(ctx, updatable); err != nil {
		return commands.UserCustomResult{}, err
	}
	return cmd.FromEntity(ctx, user), nil
}
