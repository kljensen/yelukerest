package main

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"
)

type msg struct {
	eventType string
	data      string
}

// A single broker will be created in this program. It is responsible
// for keeping a list of which clients (browsers) are currently attached
// and broadcasting events (messages) to those clients.
//
type broker struct {

	// Create a map of clients, the keys of the map are the channels
	// over which we can push messages to attached clients.  (The values
	// are just booleans and are meaningless.)
	//
	clients map[chan msg]bool

	// Channel into which new clients can be pushed
	//
	newClients chan chan msg

	// Channel into which disconnected clients should be pushed
	//
	defunctClients chan chan msg

	// Channel into which messages are pushed to be broadcast out
	// to attahed clients.
	//
	messages chan msg
}

func (b *broker) SendMessage(message msg) int {
	i := 0
	for s := range b.clients {
		s <- message
		i++
	}
	return i
}

// This broker method starts a new goroutine.  It handles
// the addition & removal of clients, as well as the broadcasting
// of messages out to clients that are currently attached.
//
func (b *broker) Start() {

	// Start a goroutine
	//
	go func() {

		// Loop endlessly
		//
		for {
			numTicks := 0

			// Block until we receive from one of the
			// three following channels.
			select {

			case s := <-b.newClients:

				// There is a new client attached and we
				// want to start sending them messages.
				b.clients[s] = true
				log.Println("Added new client")

			case s := <-b.defunctClients:

				// A client has dettached and we want to
				// stop sending them messages.
				delete(b.clients, s)
				close(s)

				log.Println("Removed client")

			case <-time.After(30 * time.Second):
				// This tick is sent in order to keep the SSE
				// connection "alive". Some browsers and proxies
				// will otherwise terminate the connection.
				numClients := b.SendMessage(msg{"tick", strconv.Itoa(numTicks)})
				numTicks++
				log.Printf("Sent tick message to %d clients\n", numClients)

			case thisMsg := <-b.messages:

				// There is a new message to send.  For each
				// attached client, push the new message
				// into the client's message channel.
				numClients := b.SendMessage(thisMsg)
				log.Printf("Sent %s message to %d clients\n", thisMsg.data, numClients)
			}
		}
	}()

}

// This broker method handles and HTTP request at the "/events/" URL.
//
func (b *broker) ServeHTTP(w http.ResponseWriter, r *http.Request) {

	// Make sure that the writer supports flushing.
	//
	f, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported!", http.StatusInternalServerError)
		return
	}

	// Create a new channel, over which the broker can
	// send this client messages.
	messageChan := make(chan msg)

	// Add this client to the map of those that should
	// receive updates
	b.newClients <- messageChan

	// Listen to the closing of the http connection via the CloseNotifier
	notify := w.(http.CloseNotifier).CloseNotify()
	go func() {
		<-notify
		// Remove this client from the map of attached clients
		// when `EventHandler` exits.
		b.defunctClients <- messageChan
		log.Println("HTTP connection just closed.")
	}()

	// Set the headers related to event streaming.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	// Don't close the connection, instead loop endlessly.
	for {

		// Read from our messageChan.
		msg, open := <-messageChan

		if !open {
			// If our messageChan was closed, this means that the client has
			// disconnected.
			break
		}

		// Write to the ResponseWriter, `w`.
		fmt.Fprintf(w, "event: %s\n", msg.eventType)
		fmt.Fprintf(w, "data: \"%s\"\n\n", msg.data)

		// Flush the response.  This is only possible if
		// the repsonse supports streaming.
		f.Flush()
	}

	// Done.
	log.Println("Finished HTTP request at ", r.URL.Path)
}
