package main

// Structured tracing for the OAuth login and consent flow.
//
// Diagnosing a failed connect from the application logs was guesswork. All
// they said was "rejecting a consent submission with a missing, stale, or
// mismatched CSRF token", which names three quite different causes and
// distinguishes none of them:
//
//   - the browser sent no session cookie, so the server saw a brand new
//     session with no outstanding forms at all;
//   - the session was right but the form had already been submitted;
//   - a different consent page had been rendered since, in a design where that
//     used to invalidate this one;
//   - the challenge in the form did not match any form we issued.
//
// Each needs a different fix, and telling them apart after the fact was
// impossible. This records enough to tell them apart and nothing more.
//
// NOTHING SECRET IS LOGGED. Session ids and CSRF tokens appear only as short
// fingerprints -- a truncated SHA-256 -- which are useless for authenticating
// but let two log lines be recognised as referring to the same session or the
// same form. Challenges are Hydra-issued, opaque, and single-use, and are also
// fingerprinted rather than printed, since a full one is long enough to make
// the logs unreadable.

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"strconv"
	"strings"
)

// fingerprint reduces an opaque value to something safe to log that still
// lets two occurrences be matched. Eight hex characters is enough to correlate
// entries within one debugging session and far too little to reverse.
func fingerprint(value string) string {
	if value == "" {
		return "-"
	}
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:8]
}

// browserHint summarises the client without recording a full user agent.
// Whether a request is a top-level navigation, and whether it arrived with a
// session cookie at all, is most of what matters when a flow misbehaves.
func browserHint(r *http.Request) string {
	fetchSite := r.Header.Get("Sec-Fetch-Site")
	if fetchSite == "" {
		fetchSite = "unset"
	}
	fetchMode := r.Header.Get("Sec-Fetch-Mode")
	if fetchMode == "" {
		fetchMode = "unset"
	}
	hasCookie := "no"
	if r.Header.Get("Cookie") != "" {
		hasCookie = "yes"
	}
	return "fetch_site=" + fetchSite + " fetch_mode=" + fetchMode + " cookie_present=" + hasCookie
}

// traceOAuth writes one line per interesting step. The prefix is grepped in
// docs/hydra.md's debugging section, so keep it stable.
func traceOAuth(step string, fields ...string) {
	log.Printf("oauth-trace step=%s %s", step, strings.Join(fields, " "))
}

func itoa(n int) string { return strconv.Itoa(n) }

func kv(key, value string) string {
	if value == "" {
		value = "-"
	}
	return key + "=" + value
}
