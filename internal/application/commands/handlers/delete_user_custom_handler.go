package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// DeleteUserCustomCommandHandler triggers a hard delete. Returns struct{} so the wire
// layer can honor the REST convention of 204 No Content — the framework's
// RespondWithSuccess with status 204 emits the success envelope without a
// data field (struct{} marshals to {} and json:"data,omitempty" prunes it).
//
// cmd.ApplyTo runs AFTER FindByDocument and BEFORE GetDeletable — same seam
// for ctx → authz translation the framework's DeleteCommandHandler exposes
// on the canonical surface.
//
// FK ON DELETE CASCADE on addresses handles the child rows; the framework's
// relational engine Delete runs the DELETE + outbox INSERT in the same TX.
type DeleteUserCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *DeleteUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.DeleteUserCustomCommand,
) (struct{}, error) {
	repo := h.Repo.Scope(ctx)
	user, err := repo.FindByDocument(cmd.DocumentKey)
	if err != nil {
		return struct{}{}, err
	}

	cmd.ApplyTo(ctx, user)
	deletable, err := domain.GetDeletable(user, h.Service, "GetDeletable")
	if err != nil {
		return struct{}{}, err
	}

	if err := repo.Delete(deletable); err != nil {
		return struct{}{}, err
	}
	return struct{}{}, nil
}
