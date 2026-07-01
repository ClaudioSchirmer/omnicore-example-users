package requests

// UserCustomKeyRequest is the shared Request DTO for the bodyless verbs of
// /showcase/users-custom/* — Archive, Unarchive, Delete. Each of the three
// routes chains fwweb.BindPath(c, &req) to populate Document from the
// :document URL segment, then assembles its specific *XxxUserCustomCommand
// inline (the Command-side mapping is a one-liner: cmd.DocumentKey = req.Document).
//
// Shared rather than per-endpoint because the wire shape is identical
// across the three verbs — the symmetric design choice to the response
// side, where the same three writes reuse a single UserCustomResponse for the
// success body. Both choices follow the rule "one Request DTO per distinct
// wire shape, regardless of how many endpoints consume it".
//
// Carrying a Request DTO (instead of reading c.Params("email") directly on
// the route) closes the structural-symmetry gap with the body-carrying
// PUT/PATCH custom routes: every endpoint of the manual showcase now
// exposes its identifier through a tagged struct field, so a reverse-
// engineering pass (OpenAPI generator, client-codegen, contract diff tool)
// can introspect the route's Request type via reflection and discover the
// :document path parameter without having to grep the Fiber handler body.
type UserCustomKeyRequest struct {
	Document string `path:"document"`
}
