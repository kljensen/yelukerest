package main

import (
	"io"
	"net/http"
	"net/url"
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

func getLoginHandler(casBaseURI, servicePath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		// Check for X-Forwarded-Proto if behind a reverse proxy
		if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
			scheme = proto
		}

		port := ""
		if r.URL.Port() != "" {
			port = ":" + r.URL.Port()
		}

		// Build up the service URL. This is the place
		// to which the CAS server will redirect the user
		// after they have authenticated.
		serviceURI := url.URL{
			Scheme: scheme,
			Host:   r.Host + port,
			Path:   servicePath,
		}
		serviceURIValues := url.Values{}
		next := r.URL.Query().Get("next")
		if next != "" {
			serviceURIValues.Add("next", next)
		}
		serviceURI.RawQuery = serviceURIValues.Encode()

		// Now add this onto our CAS login URL
		urlValues := url.Values{}
		urlValues.Add("service", serviceURI.String())
		fullCASURI := casBaseURI + "/login?" + urlValues.Encode()

		http.Redirect(w, r, fullCASURI, http.StatusTemporaryRedirect)
	}
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
	next := r.URL.Query().Get("next")
	if next != "" {
		http.Redirect(w, r, next, http.StatusTemporaryRedirect)
		return
	}
	io.WriteString(w, "You are authenticated as "+netid)
}
