package main

import (
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

var casUserRegexp = regexp.MustCompile("<cas:user>(.*?)</cas:user>")

func isValidCASURI() bool {
	return strings.HasPrefix(casURI, "http")
}

// uriWithoutTicket returns the URI without the ticket query parameter.
// All other query parameters are preserved.
func uriWithoutTicket(r *http.Request) string {
	params := r.URL.Query()
	params.Del("ticket")
	// Return everything including protocol, host, port, path, and query string
	return r.URL.Scheme + "://" + r.URL.Host + r.URL.Port() + r.URL.Path + "?" + params.Encode()
}

func getCASValidationURL(ticket string, r *http.Request) string {
	return casURI + "/serviceValidate?ticket=" + ticket + "&service=" + uriWithoutTicket(r)
}

func authenticateHandler(w http.ResponseWriter, r *http.Request) {
	// TODO: do not hardcode this. Also, allow a "next" parameter
	// that we will use in the /auth/validate handler to redirect
	// the user back to the original page. STOPPED HERE WIP.
	service := "http://localhost:5009/auth/validate"
	// Redirect to the CAS login page
	http.Redirect(w, r, casURI+"/login?service="+service, http.StatusTemporaryRedirect)
}

// Parse the user from the XML response, which looks like this:
// <cas:serviceResponse xmlns:cas="http://www.yale.edu/tp/cas">
//
//	<cas:authenticationSuccess>
//	<cas:user>johnd0</cas:user>
//	</cas:authenticationSuccess>
//
// </cas:serviceResponse>
func getCASUserFromXML(xml string) string {
	if !strings.Contains(xml, "<cas:authenticationSuccess>") {
		return ""
	}
	matches := casUserRegexp.FindStringSubmatch(xml)
	if len(matches) > 1 {
		return matches[1]
	}
	return ""
}

// Validate handler
func validateHandler(w http.ResponseWriter, r *http.Request) {
	ticket := r.URL.Query().Get("ticket")
	if ticket == "" {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}
	// We're going to use http.Get to validate the ticket
	// by contacting the CAS server.
	var timeout = 5 * time.Second
	client := http.Client{
		Timeout: timeout,
	}
	url := getCASValidationURL(ticket, r)
	resp, err := client.Get(url)
	if err != nil {
		http.Error(w, "CAS server error", http.StatusInternalServerError)
		return
	}

	// Check the response status code
	if resp.StatusCode != http.StatusOK {
		http.Error(w, "CAS server error", http.StatusInternalServerError)
		return
	}

	// Read the response body as string
	maxSize := int64(1 << 20) // 1 MB in bytes
	limitedReader := io.LimitReader(resp.Body, maxSize)

	body, err := io.ReadAll(limitedReader)
	if err != nil {
		http.Error(w, "CAS server error", http.StatusInternalServerError)
		return
	}

	defer resp.Body.Close()

	// Parse the user from the XML response
	netid := getCASUserFromXML(string(body))
	if netid == "" {
		// not authenticated
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	// Set the netid in the session
	sessionManager.RenewToken(r.Context())
	sessionManager.Put(r.Context(), "netid", netid)
	io.WriteString(w, "You are authenticated as "+netid)
}
