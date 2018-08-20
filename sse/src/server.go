// Golang HTML5 Server Side Events Example
//
// Run this code like:
//  > go run server.go
//
// Then open up your browser to http://localhost:8000
// Your browser must support HTML5 SSE, of course.

package main

import (
	"html/template"
	"log"
	"net/http"
	"os"
	"time"
)

const indexTemplate = `
<!DOCTYPE html>
<html>
<head>
	<title>HTML5 Server Side Event Example in Go</title>
</head>
<body>

	Yo {{.}}, here are some facinating messages about the
	current time:<br>

	<script type="text/javascript">

	    // Create a new HTML5 EventSource
	    var source = new EventSource('./events/');

	    // Create a callback for when a new message is received.
	    source.onmessage = function(e) {

	        // Append the 'data' attribute of the message to the DOM.
	        document.body.innerHTML += e.data + '<br>';
	    };
	</script>
</body>
</html>
`

// Handler for the main page, which we wire up to the
// route at "/" below in `main`.
//
func handler(w http.ResponseWriter, r *http.Request) {

	// Did you know Golang's ServeMux matches only the
	// prefix of the request URL?  It's true.  Here we
	// insist the path is just "/".
	if r.URL.Path != "/" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Read in the template with our SSE JavaScript code.
	t := template.Must(template.New("index").Parse(indexTemplate))

	// Render the template, writing to `w`.
	t.Execute(w, "friend")

	// Done.
	log.Println("Finished HTTP request at ", r.URL.Path)
}

// Main routine
//
func main() {

	amqpURL := os.Getenv("AMQP_URI")

	// Make a new broker instance
	b := &broker{
		make(map[chan string]bool),
		make(chan (chan string)),
		make(chan (chan string)),
		make(chan string),
	}

	// Start processing events
	b.Start()

	// Make b the HTTP handler for "/events/".  It can do
	// this because it has a ServeHTTP method.  That method
	// is called in a separate goroutine for each
	// request to "/events/".
	http.Handle("/events/", b)

	// Generate a constant stream of events that get pushed
	// into the broker's messages channel and are then broadcast
	// out to any clients that are attached.
	go func() {
		for i := 0; ; i++ {
			log.Println("Connecting to RabbitMQ")

			// Send messages to attached clients
			getMessages(amqpURL, "amq.topic", "row_change.#", b.messages)

			// Print a nice log message and sleep for 5s.
			// log.Printf("Sent message %d ", i)
			log.Println("Sleeping for 5s")
			time.Sleep(5 * 1e9)
		}
	}()

	// When we get a request at "/", call `handler`
	// in a new goroutine.
	http.Handle("/", http.HandlerFunc(handler))

	// Start the server and listen forever on port 8000.
	http.ListenAndServe(":"+os.Getenv("PORT"), nil)
}
