package message

import (
	"errors"
	"strings"

	"gno.land/p/moul/ulist/v0"
	"gno.land/p/nt/bptree/v0"
)

var (
	// ErrInvalidTopic is triggered when an invalid topic is used.
	ErrInvalidTopic = errors.New("invalid topic")

	// ErrRequiredCallback is triggered when subscribing without a callback.
	ErrRequiredCallback = errors.New("message callback is required")

	// ErrRequiredSubscriptionID is triggered when unsubscribing without an ID.
	ErrRequiredSubscriptionID = errors.New("message sibscription ID is required")

	// ErrRequiredTopic is triggered when (un)subscribing without a topic.
	ErrRequiredTopic = errors.New("message topic is required")
)

// NewBroker creates a new message broker.
func NewBroker() *Broker {
	return &Broker{
		callbacks: bptree.NewBPTree32(),
	}
}

// Broker is a message broker that handles subscriptions and message publishing.
type Broker struct {
	callbacks *bptree.BPTree // string(topic) -> *ulist.List(Callback)
}

// Topics returns the list of current subscription topics.
func (b *Broker) Topics() []Topic {
	var topics []Topic
	b.callbacks.Iterate("", "", func(k string, _ any) bool {
		topic := Topic(k)
		if topic == TopicAll {
			// Skip catchall topic from the list
			return false
		}

		topics = append(topics, topic)
		return false
	})
	return topics
}

// Subscribe subscribes to messages published for a topic.
// It returns the callback ID within the topic.
func (b *Broker) Subscribe(topic Topic, cb Callback) (id int, _ error) {
	key := strings.TrimSpace(string(topic))
	if key == "" {
		return 0, ErrRequiredTopic
	}

	if cb == nil {
		return 0, ErrRequiredCallback
	}

	callbacks, _ := b.callbacks.Get(key).(*ulist.List)
	if callbacks == nil {
		callbacks = ulist.New()
	}

	callbacks.Append(cb)
	b.callbacks.Set(key, callbacks)
	return callbacks.TotalSize(), nil
}

// Unsubscribe unsubscribes a callback from a message topic.
// ID is the callback ID within the topic, returned on subscription.
func (b *Broker) Unsubscribe(topic Topic, id int) (unsubscribed bool, _ error) {
	key := strings.TrimSpace(string(topic))
	if key == "" {
		return false, ErrRequiredTopic
	}

	if id == 0 {
		return false, ErrRequiredSubscriptionID
	}

	callbacks, ok := b.callbacks.Get(key).(*ulist.List)
	if !ok {
		return false, errors.New("message topic not found: " + key)
	}

	i := id - 1
	return callbacks.Delete(i) == nil, nil
}

// Publish publishes a message for a topic.
func (b *Broker) Publish(topic Topic, data any) error {
	if topic == TopicAll {
		return ErrInvalidTopic
	}

	key := strings.TrimSpace(string(topic))
	if key == "" {
		return ErrRequiredTopic
	}

	iterCb := func(_ int, v any) bool {
		cb := v.(Callback)
		cb(Message{topic, data})
		return false
	}

	// Trigger callbacks subscribed to current topic
	if callbacks, ok := b.callbacks.Get(key).(*ulist.List); ok {
		callbacks.Iterator(0, callbacks.Size(), iterCb)
	}

	// Trigger callbacks subscribed to all topics
	if callbacks, ok := b.callbacks.Get(string(TopicAll)).(*ulist.List); ok {
		callbacks.Iterator(0, callbacks.Size(), iterCb)
	}
	return nil
}
