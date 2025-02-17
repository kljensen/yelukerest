package main

import (
	"crypto/tls"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/alexedwards/scs/v2"
)

var casUserRegexp = regexp.MustCompile("<cas:user>(.*?)</cas:user>")

func isValidCASURI(casURI string) bool {
	validPrefixes := []string{"http://", "https://"}
	for _, prefix := range validPrefixes {
		if strings.HasPrefix(casURI, prefix) {
			return true
		}
	}
	return false
}

func getRequestScheme(r *http.Request) string {
	scheme := "http"
	// Check X-Forwarded-Proto header
	if forwardedProto := r.Header.Get("X-Forwarded-Proto"); forwardedProto != "" {
		scheme = forwardedProto
	} else if r.TLS != nil {
		scheme = "https"
	} else if r.Header.Get("X-Forwarded-Ssl") == "on" {
		scheme = "https"
	} else if strings.HasPrefix(r.Header.Get("X-Forwarded-Scheme"), "https") {
		scheme = "https"
	}
	if r.TLS != nil {
		scheme = "https"
	}
	return scheme
}

func getRequestHost(r *http.Request) string {
	host := r.Host
	// Check X-Forwarded-Host header
	if forwardedHost := r.Header.Get("X-Forwarded-Host"); forwardedHost != "" {
		host = forwardedHost
	}
	return host
}

// uriWithoutTicket returns the URI without the ticket query parameter.
// All other query parameters are preserved.
func uriWithoutTicket(r *http.Request) string {
	scheme := getRequestScheme(r)
	host := getRequestHost(r)

	query := r.URL.Query()
	query.Del("ticket")

	uri := &url.URL{
		Scheme:   scheme,
		Host:     host,
		Path:     r.URL.Path,
		RawQuery: query.Encode(),
	}

	return uri.String()

}

func getCASValidationURL(config CASConfig, ticket string, r *http.Request) (string, error) {
	// Parse the casURI string to object
	// and add the ticket and service parameters
	// to it.
	url, err := url.Parse(config.RemoteValidationURI)
	if err != nil {
		return "", err
	}
	service := uriWithoutTicket(r)
	// TODO: i'm losing the /cas here! need to keep it
	query := url.Query()
	query.Add("ticket", ticket)
	query.Add("service", service)
	url.RawQuery = query.Encode()
	return url.String(), nil
}

// Struct to hold CAS config
type CASConfig struct {
	RemoteURI           string
	RemoteValidationURI string
	ReturnPath          string
	IsDevelopment       bool
}

func getLoginHandler(config CASConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		scheme := getRequestScheme(r)
		host := getRequestHost(r)

		// Build up the service URL. This is the place
		// to which the CAS server will redirect the user
		// after they have authenticated.
		serviceURI := url.URL{
			Scheme: scheme,
			Host:   host,
			Path:   config.ReturnPath,
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
		fullCASURI := config.RemoteURI + "?" + urlValues.Encode()

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

func getValidateHandler(casConfig CASConfig, jwtConfig FetchJWTConfig, sessionManager *scs.SessionManager) http.HandlerFunc {

	// Validate handler
	return func(w http.ResponseWriter, r *http.Request) {
		ticket := r.URL.Query().Get("ticket")
		if ticket == "" {
			http.Error(w, "Bad request", http.StatusBadRequest)
			return
		}
		// We're going to use http.Get to validate the ticket
		// by contacting the CAS server.
		var timeout = 5 * time.Second
		tr := http.DefaultTransport
		if casConfig.IsDevelopment {
			tr = &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			}
		}
		client := http.Client{
			Timeout:   timeout,
			Transport: tr,
		}
		url, err := getCASValidationURL(casConfig, ticket, r)
		log.Println("Validating ticket at URL:", url)
		if err != nil {
			log.Println("CAS server error 0:", err)
			http.Error(w, "CAS server error 0:", http.StatusInternalServerError)
			return
		}
		resp, err := client.Get(url)
		if err != nil {
			log.Println("URL is ", url)
			log.Println("CAS server error 1:", err)
			log.Println(resp)
			http.Error(w, "CAS server error 1:", http.StatusInternalServerError)
			return
		}

		// Check the response status code
		if resp.StatusCode != http.StatusOK {
			log.Println("CAS server error 2:", err)
			log.Println(resp)
			http.Error(w, "CAS server error 2:", http.StatusInternalServerError)
			return
		}

		// Read the response body as string
		maxSize := int64(1 << 20) // 1 MB in bytes
		limitedReader := io.LimitReader(resp.Body, maxSize)

		body, err := io.ReadAll(limitedReader)
		if err != nil {
			log.Println("CAS server error 3:", err)
			http.Error(w, "CAS server error 3:", http.StatusInternalServerError)
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

		// See if this netid corresponds to a valid user
		// in the database. If not, then we should not
		// allow them to log in.
		jwtInfo, err, httpStatus := fetchUserJWTInfo(netid, jwtConfig)
		if err != nil || jwtInfo == nil {
			http.Error(w, "Unauthorized", httpStatus)
			return
		}
		if httpStatus != http.StatusOK {
			http.Error(w, http.StatusText(httpStatus), httpStatus)
			return
		}

		// Set the netid in the session
		sessionManager.RenewToken(r.Context())
		sessionManager.Put(r.Context(), "netid", netid)

		// See if there is a next parameter to which we should redirect
		// the user after they have authenticated.
		next := r.URL.Query().Get("next")
		if next == "" {
			next = "/"
		}
		// If there is no next parameter, then just show a message.
		http.Redirect(w, r, next, http.StatusTemporaryRedirect)
	}
}
