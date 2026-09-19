# Message Package

Package provides a simple message broker implementation.

The message broker is a Pub/Sub one. It implements two different interfaces,
`Publisher` and `Subscriber`, which are also defined within this package.

Published messages contain the topic where they are published and optional
message data. Subscribing to the `TopicAll` topic triggers the callback for
messages published to any topic.

Repository can be found at [jeronimoalbi/gnome](https://github.com/jeronimoalbi/gnome),
as part of `jeronimoalbi`'s Gno smart contracts monorepo.

## Usage

[embedmd]:# (filetests/readme_filetest.gno go)
```go
package main

import "gno.land/p/jeronimoalbi/message"

func main() {
	broker := message.NewBroker()

	// Subscribe to an event
	subID, err := broker.Subscribe("EventName", func(msg message.Message) {
		println("EventName has been triggered:", msg.Data.(string))
	})
	if err != nil {
		panic(err)
	}

	// Publish an event
	err = broker.Publish("EventName", "Example event data")
	if err != nil {
		panic(err)
	}

	// Unsubscribe from the event
	unsubscribed, err := broker.Unsubscribe("EventName", subID)
	if err != nil {
		panic(err)
	}

	if !unsubscribed {
		panic("subscription not found")
	}

	// Nothing is triggered after unsubscribing
	err = broker.Publish("EventName", "Ignored event data")
	if err != nil {
		panic(err)
	}
}

// Output:
// EventName has been triggered: Example event data
```
