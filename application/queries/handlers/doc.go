// Package handlers holds the manual query (read) handlers consumed by the
// /showcase/users-custom/* showcase and the /audit/:aggregateId route —
// co-located with the queries they resolve under application/queries. Each
// handler implements pipeline.Handler[*Query, TRes] explicitly — resolving a
// ReadCriteria from the Query, calling the ViewReader, and returning the doc
// (or a queries.Page) for the route to project. The canonical /users/* surface
// reuses the framework's generic FindByIDQueryHandler / FindByParamsQueryHandler;
// writing the chain by hand here documents what those wrappers do under the cover
// and carries the row-level access-control seam between ToCriteria and ReadPage.
//
// Its write-side twin is application/commands/handlers.
package handlers
