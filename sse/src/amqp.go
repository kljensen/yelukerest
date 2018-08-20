package main

import (
	"github.com/streadway/amqp"
)

func getMessages(rabbitMQURL string, exchangeName string, routingKey string, destinationChan chan string) error {
	// user := os.Getenv("USER")
	// pass := os.Getenv("PASS")
	// conn, err := amqp.Dial("amqp://" + user + ":" + pass + "@localhost:5672/")
	conn, err := amqp.Dial(rabbitMQURL)
	if err != nil {
		return err
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	err = ch.ExchangeDeclare(
		exchangeName, // name
		"topic",      // type
		true,         // durable
		false,        // auto-deleted
		false,        // internal
		false,        // no-wait
		nil,          // arguments
	)
	if err != nil {
		return err
	}

	q, err := ch.QueueDeclare(
		"",    // name
		false, // durable
		false, // delete when unused
		true,  // exclusive
		false, // no-wait
		nil,   // arguments
	)
	if err != nil {
		return err
	}

	err = ch.QueueBind(
		q.Name, // queue name
		// "row_change.#", // routing key
		routingKey,   // routing key
		exchangeName, // exchange
		false,
		nil)
	if err != nil {
		return err
	}

	msgs, err := ch.Consume(
		q.Name, // queue
		"",     // consumer
		true,   // auto-ack
		false,  // exclusive
		false,  // no-local
		false,  // no-wait
		nil,    // args
	)
	if err != nil {
		return err
	}

	for d := range msgs {
		// When we change this to send bodies, we'll
		// want d.Body. For now, send routing key.
		destinationChan <- d.RoutingKey
	}
	return nil
}
