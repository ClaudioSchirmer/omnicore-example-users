package handlers

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
)

func testCtx() *configuration.AppContext {
	return configuration.NewAppContextWithRandomID(configuration.LangPTBR)
}

// fakeViewReader satisfies queries.ViewReader for read-handler tests.
// Counters track invocations; gotView/gotCriteria/gotID expose what the
// handler asked for so the test can assert the filter seam wrote the
// expected criteria. Both ReadPage and ReadByID record the same
// ReadCriteria — symmetric with the production port.
type fakeViewReader struct {
	readPageCalled int
	readByIDCalled int

	gotView     string
	gotCriteria queries.ReadCriteria
	gotID       string

	pageToReturn queries.Page
	pageErr      error

	docToReturn map[string]any
	docFound    bool
	docErr      error
}

func (r *fakeViewReader) ReadPage(_ context.Context, view string, c queries.ReadCriteria) (queries.Page, error) {
	r.readPageCalled++
	r.gotView = view
	r.gotCriteria = c
	return r.pageToReturn, r.pageErr
}

func (r *fakeViewReader) ReadByID(_ context.Context, view, id string, c queries.ReadCriteria) (map[string]any, bool, error) {
	r.readByIDCalled++
	r.gotView = view
	r.gotID = id
	r.gotCriteria = c
	return r.docToReturn, r.docFound, r.docErr
}
