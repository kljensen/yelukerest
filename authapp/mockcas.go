package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
)

var ticketStore = make(map[string]string)

func getCASLoginForm(user_id, service string) string {
	var casForm = `
	<html>
		<head>
			<title>MockCAS</title>
		</head>
		<body>
			<h1>Fill in the netid with with you want to authenticate!</h1>
			<form method="GET">
				<div>
					<label for="id">Netid:</label>
				</div>
				<div>
					<input type="text" name="id" value="%s">
				</div>
				<div>
					<label for="service">Service:</label>
				</div>
				<div>
					<input type="text" name="service" value="%s">
				</div>
				<button type="submit">Submit</button>
			</form>
		</body>
	</html>
	`
	return fmt.Sprintf(casForm, user_id, service)
}

func getFailureHTML(ticket string) string {
	return fmt.Sprintf(`<cas:serviceResponse xmlns:cas="https://www.yale.edu/tp/cas"><cas:authenticationFailure code="INVALID_TICKET">Ticket "%s" not recognized</cas:authenticationFailure></cas:serviceResponse>`, ticket)
}

func getSuccessHTML(user_id string) string {
	return fmt.Sprintf(`<cas:serviceResponse xmlns:cas="https:/www.yale.edu/tp.cas"><cas:authenticationSuccess><cas:user>%s</cas:user><cas:foo>bar</cas:foo></cas:authenticationSuccess></cas:serviceResponse>`, user_id)
}

func redirectToService(w http.ResponseWriter, r *http.Request, user_id, service string) {
	ticket := "mock-ticket-" + user_id
	ticketStore[ticket] = user_id

	// Parse the service string as URL
	log.Println("Redirecting to service:", service)
	serviceURL, err := url.Parse(service)
	if err != nil {
		http.Error(w, "Bad request. Invalid 'service' parameter.", http.StatusBadRequest)
		return
	}
	// Add the ticket
	serviceParams := url.Values{}
	serviceParams.Add("ticket", ticket)

	// Add the next parameter if it exists
	next := serviceURL.Query().Get("next")
	if next != "" {
		serviceParams.Add("next", next)
	}
	serviceURL.RawQuery = serviceParams.Encode()

	http.Redirect(w, r, serviceURL.String(), http.StatusTemporaryRedirect)
}

// Login handler
func login(w http.ResponseWriter, r *http.Request) {
	args := r.URL.Query()
	user_id := args.Get("id")
	service := args.Get("service")

	if user_id == "" || service == "" {
		io.WriteString(w, getCASLoginForm(user_id, service))
	} else {
		redirectToService(w, r, user_id, service)
	}
}

// service validate handler
func serviceValidate(w http.ResponseWriter, r *http.Request) {
	ticket := r.URL.Query().Get("ticket")
	if ticket == "" {
		http.Error(w, "Bad request. Missing 'ticket' parameter.", http.StatusBadRequest)
		return
	}

	// Set the content type to text/xml
	w.Header().Set("Content-Type", "text/xml")

	user_id, ok := ticketStore[ticket]
	var xml string
	if ok {
		xml = getSuccessHTML(user_id)
	} else {
		xml = getFailureHTML(ticket)
	}
	io.WriteString(w, xml)
}
