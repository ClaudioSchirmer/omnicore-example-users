//go:build qa

package qafixtures

import (
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// TestEchoValuesHandler_EchoesValuesNotAddresses is the fast twin of
// status_mapping.sh §4: the suite proves it over real HTTP, this proves it
// without a server, so a regression is caught by `go test` before anyone boots
// anything.
//
// The bug it guards against rendered every POINTER — which is what every
// optional field is — as a memory address. It survived for as long as it did
// because an address is a valid rendering of a pointer: nothing errored, and
// any assertion that merely checked "a value came back" passed either way.
func TestEchoValuesHandler_EchoesValuesNotAddresses(t *testing.T) {
	_, err := (&EchoValuesHandler{}).Handle(nil, &EchoValuesQuery{})
	if err == nil {
		t.Fatal("the handler must fail — it exists to emit notifications")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected a NotificationCarrier, got %T", err)
	}

	got := map[string]string{}
	for _, ctx := range carrier.NotificationContexts() {
		for _, m := range ctx.Messages() {
			got[m.ResolveFieldName()] = m.FieldValue
		}
	}

	want := map[string]string{
		"valueInt":         "15",
		"valueString":      "plain",
		"valueRawVO":       "ana@corp.com",
		"pointerInt":       "15",
		"pointerInt64":     "-7",
		"pointerFloat":     "2.5",
		"pointerBool":      "true",
		"pointerString":    "plain",
		"pointerRawVO":     "ana@corp.com",
		"pointerStrEnumVO": "white",
		// An int-backed enum echoes its UNDERLYING int. The translated label
		// needs the request language and lives at the boundary, not in domain.
		"pointerIntEnumVO": "3",
		// A type that renders itself keeps its own rendering through a pointer.
		"pointerStringer": "vo(x)",
		"valueTime":       "2026-08-15 10:30:00 +0000 UTC",
		"pointerTime":     "2026-08-15 10:30:00 +0000 UTC",
		// An absent value is not a value.
		"nilPointer": "",
	}
	for field, exp := range want {
		if got[field] != exp {
			t.Errorf("%s: FieldValue = %q, want %q", field, got[field], exp)
		}
	}

	// The shape assertion, deliberately not per-field: it covers every echo the
	// handler emits today AND every one added later, which is what would have
	// caught the original bug without anyone thinking to look for it.
	for field, v := range got {
		if strings.HasPrefix(v, "0x") {
			t.Errorf("%s leaked a pointer address into FieldValue: %q", field, v)
		}
	}
}

// asCarrier is errors.As spelled out, so the test reads without an import that
// exists only to unwrap.
func asCarrier(err error, target *domain.NotificationCarrier) bool {
	c, ok := err.(domain.NotificationCarrier)
	if ok {
		*target = c
	}
	return ok
}
