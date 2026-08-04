package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// Relationship is the Dependent child's kinship enum value object — a closed
// classification set, string-backed: the value IS the wire/persisted token.
// The framework validates membership; Relationship writes no IsValid.
type Relationship string

// String-backed: the token IS the value, so reordering the block never changes
// it (no iota to shift). The empty string is the zero sentinel — never a member.
const (
	RelationshipUnknown  Relationship = ""
	RelationshipSpouse   Relationship = "spouse"
	RelationshipSon      Relationship = "son"
	RelationshipDaughter Relationship = "daughter"
	RelationshipFather   Relationship = "father"
	RelationshipMother   Relationship = "mother"
	RelationshipOther    Relationship = "other"
)

var relationshipMembers = []Relationship{
	RelationshipSpouse, RelationshipSon, RelationshipDaughter,
	RelationshipFather, RelationshipMother, RelationshipOther,
}

func (r Relationship) Value() string          { return string(r) }
func (r Relationship) Values() []Relationship { return relationshipMembers }
func (r Relationship) UnknownNotification() domain.Notification {
	return UnknownRelationshipNotification{}
}
