package main

import (
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
)

// TestMountUsersGraphQL_SchemaBuilds asserts the User aggregate contributes a
// valid GraphQL schema into the single registry — the read Query, the create
// Mutation, and the bodyless archive/delete mutations are all present, and
// gqlparser accepts the generated SDL. Registration is cumulative: this drives
// the same UsersFeature.MountGraphQL → web.MountUsersGraphQL path Wire uses.
// Building the schema is pure reflection (no DB), so a nil relational engine is
// fine — the repo is constructed over it but never queried (and the test stays
// backend-neutral: it names no concrete engine).
func TestMountUsersGraphQL_SchemaBuilds(t *testing.T) {
	d := bootstrap.Deps{
		Pipeline: pipeline.New(translation.Default()),
		DB:       nil,
	}
	users := NewUsersFeature(d)

	gql := fwgraphql.New(d.Pipeline)
	users.MountGraphQL(gql, d) // cumulative: this feature adds its fields

	sdl, err := gql.SDL()
	if err != nil {
		t.Fatalf("GraphQL schema failed to build/validate: %v", err)
	}
	for _, want := range []string{
		"type Query", "users(",
		"user(id: ID!, includeArchived: Boolean): User",
		// The RelationalSource twins — same DTOs, same node type, SoR backing.
		"usersRel(",
		"userRel(id: ID!, includeArchived: Boolean): User",
		// The typed order vocabulary, reflected from the FindUsers Response.
		"orderBy: [UserOrder!]",
		"enum UserOrderField", "enum OrderDirection",
		"direction: OrderDirection = ASC",
		"type Mutation",
		"createUser(", "updateUser(", "patchUser(",
		"archiveUser(", "unarchiveUser(", "deleteUser(",
		"type User", "UserConnection",
		// Mutation type names derive from the FIELD name (Relay/GitHub
		// convention), never from the Go DTO names.
		"input CreateUserInput", "input UpdateUserInput", "input PatchUserInput",
		"type CreateUserPayload", "type UpdateUserPayload", "type PatchUserPayload",
		// Bodyless mutations own field-derived payloads too — no shared type.
		"archiveUser(id: ID!): ArchiveUserPayload!",
		"type ArchiveUserPayload", "type UnarchiveUserPayload", "type DeleteUserPayload",
	} {
		if !strings.Contains(sdl, want) {
			t.Errorf("generated SDL missing %q\n---\n%s", want, sdl)
		}
	}
	if strings.Contains(sdl, "MutationResult") {
		t.Errorf("shared MutationResult must be gone from the SDL\n---\n%s", sdl)
	}
}
