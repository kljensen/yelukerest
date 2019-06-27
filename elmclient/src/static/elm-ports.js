/* jslint browser: true */
/* global EventSource */
/* exported initElmPorts */

// From https://github.com/gpremer/elm-sse-ports

// Copyright (c) 2016 Geert Premereur

// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.


exports.default = function initElmPorts(app) {
    const sources = {};
    /**
     * sendEventToElm
     * @param  {sseevent} event The event received
     * @returns {And eventsource object} null
     */
    function sendEventToElm(event) {
        // console.log(event);
        app.ports.ssEventsJS.send({
            data: event.data, // Can't be null according to spec
            eventType: event.type, // Can't be because we listen for this event type
            id: event.id || null,
        });
    }

    // We could have one function for typed and untyped, but
    // then need to either expose Maybe to users or make
    // superfluous copy.
    /**
     * sendUntypedEventToElm
     * @param  {sseevent} event The event received
     * @returns {null} null
     */
    function sendUntypedEventToElm(event) {
        app.ports.ssUntypedEventsJS.send({
            data: event.data, // Can't be null according to spec
            eventType: null,
            id: event.id || null,
        });
    }

    /**
     * createNewEventSource
     * @param  {foo} address Foo
     * @returns {null} null
     */
    function createNewEventSource(address) {
        sources[address] = new EventSource(address); // we only call if there isn't one yet

        return sources[address];
    }
    /**
     * addEventHandlers
     * @param  {string} eventType - The type of event
     * @param  {eventSource} eventSource - The event source
     * @returns {null} null
     */
    function addEventHandlers(eventType, eventSource) {
        if (eventType) {
            eventSource.addEventListener(eventType, sendEventToElm);
        } else {
            eventSource.onmessage = sendUntypedEventToElm; // eslint-disable-line no-param-reassign
        }
        eventSource.onerror = (err) => { // eslint-disable-line no-param-reassign
            console.log('Encountered an error:', err); // eslint-disable-line
        };
    }
    /**
     * @param  {string} address The server address
     * @param  {string} eventType Type of event
     * @param  {boolean} doCreate=false Should we create new event source?
     * @returns {eventSource} An eventsource object
     */
    function doAddListener(address, eventType, doCreate = false) {
        let eventSource;
        if (doCreate) {
            eventSource = createNewEventSource(address);
        } else {
            eventSource = sources[address];
        }
        addEventHandlers(eventType, eventSource);
        return eventSource;
    }

    // Currently unused and therefore pruned
    // app.ports.createEventSourceJS.subscribe(createNewEventSource);

    app.ports.addListenerJS.subscribe((addressAndEventType) => {
        const address = addressAndEventType[0];
        const eventType = addressAndEventType[1];
        const eventSource = doAddListener(address, eventType, false);
        eventSource.onerror = (err) => { // eslint-disable-line no-param-reassign
            console.log('Encountered an error:', err); // eslint-disable-line
        };
    });

    app.ports.createEventSourceAndAddListenerJS.subscribe((addressAndEventType) => {
        const address = addressAndEventType[0];
        const eventType = addressAndEventType[1];
        doAddListener(address, eventType, true);
    });

    // Currently unused and therefore pruned
    // app.ports.removeListenerJS.subscribe((addressAndEventType) => {
    //     const address = addressAndEventType[0];
    //     const eventType = addressAndEventType[1];
    //     const eventSource = sources[address]; // we only call if it exists
    //     eventSource.removeEventListener(eventType, sendEventToElm);
    // });

    // Currently unused and therefore pruned
    // app.ports.deleteEventSourceJS.subscribe((address) => {
    //     sources[address].close(); // we only call if it exists
    //     delete sources[address]; // we only call if it exists
    // });
};
