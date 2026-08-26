package core

import (
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

// channel.gno: channel handshake and close logic. The admin gate stays on the
// proxy entrypoint; the Force* recovery variants remain proxy admin operations.
// Each handshake step dispatches the matching callback to the channel's app.

// ChannelOpenInit starts a channel in the Init state and notifies its app. The
// created channel id is observable through the emitted event, not returned.
func (c *coreV1) ChannelOpenInit(_ int, rlm realm, msg types.MsgChannelOpenInit) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()
	portId := types.Bytes(types.CloneBytes(msg.PortId))
	connection := c.ensureConnectionState(msg.ConnectionId)
	channelId := c.store.NextChannelId(0, rlm)

	channel := core.NewChannel(
		types.ChannelStateInit,
		msg.ConnectionId,
		0,
		types.Bytes(types.CloneBytes(msg.CounterpartyPortId)),
		msg.Version,
	)
	c.store.CreateChannel(0, rlm, channelId, channel, portId)

	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	a.OnChannelOpenInit(cross(rlm), msg.ConnectionId, channelId, msg.Version, relayer)
	core.EmitChannelOpenInit(0, rlm, portId, channelId, channel, connection)
}

// ChannelOpenTry proves a counterparty Init and opens the local channel in
// TryOpen, notifying its app.
func (c *coreV1) ChannelOpenTry(_ int, rlm realm, msg types.MsgChannelOpenTry) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenTry(0, rlm, msg, true)
}

// ForceChannelOpenTry is the admin recovery variant of ChannelOpenTry that skips
// counterparty proof verification.
func (c *coreV1) ForceChannelOpenTry(_ int, rlm realm, msg types.MsgChannelOpenTry) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenTry(0, rlm, msg, false)
}

func (c *coreV1) channelOpenTry(_ int, rlm realm, msg types.MsgChannelOpenTry, verify bool) {
	relayer := rlm.Previous().Address()
	portId := types.Bytes(types.CloneBytes(msg.PortId))
	if msg.Channel.State != types.ChannelStateTryOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	if msg.Channel.CounterpartyChannelId == 0 {
		panic(makeError(core.ErrInvalidCounterpartyChannelId))
	}

	connection := c.ensureConnectionState(msg.Channel.ConnectionId)
	channelId := c.store.NextChannelId(0, rlm)

	if verify {
		expectedChannel := core.NewChannel(
			types.ChannelStateInit,
			connection.CounterpartyConnectionId,
			0,
			portId,
			msg.CounterpartyVersion,
		)
		key := types.ChannelPath(msg.Channel.CounterpartyChannelId)
		value := core.ChannelValue(expectedChannel)
		c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.ProofInit, key[:], value[:])
	}

	c.store.CreateChannel(0, rlm, channelId, msg.Channel, portId)

	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	a.OnChannelOpenTry(cross(rlm), msg.Channel.ConnectionId, channelId, msg.Channel.Version, msg.CounterpartyVersion, relayer)

	core.EmitChannelOpenTry(0, rlm, portId, channelId, msg.Channel, msg.CounterpartyVersion, connection)
}

// ChannelOpenAck proves the counterparty TryOpen and moves the local Init
// channel to Open, notifying its app.
func (c *coreV1) ChannelOpenAck(_ int, rlm realm, msg types.MsgChannelOpenAck) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenAck(0, rlm, msg, true)
}

// ForceChannelOpenAck is the admin recovery variant of ChannelOpenAck that skips
// counterparty proof verification.
func (c *coreV1) ForceChannelOpenAck(_ int, rlm realm, msg types.MsgChannelOpenAck) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenAck(0, rlm, msg, false)
}

func (c *coreV1) channelOpenAck(_ int, rlm realm, msg types.MsgChannelOpenAck, verify bool) {
	relayer := rlm.Previous().Address()

	channel, err := c.getChannel(msg.ChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateInit {
		panic(makeError(core.ErrInvalidChannelState))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)
	portId, _ := c.store.GetChannelOwner(msg.ChannelId)

	if verify {
		expectedChannel := core.NewChannel(
			types.ChannelStateTryOpen,
			connection.CounterpartyConnectionId,
			msg.ChannelId,
			portId,
			msg.CounterpartyVersion,
		)
		key := types.ChannelPath(msg.CounterpartyChannelId)
		value := core.ChannelValue(expectedChannel)
		c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.ProofTry, key[:], value[:])
	}

	updated := core.NewChannel(
		types.ChannelStateOpen,
		channel.ConnectionId,
		msg.CounterpartyChannelId,
		channel.CounterpartyPortId.Clone(),
		msg.CounterpartyVersion,
	)
	c.store.SaveChannel(0, rlm, msg.ChannelId, updated)

	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	a.OnChannelOpenAck(cross(rlm), msg.ChannelId, msg.CounterpartyChannelId, msg.CounterpartyVersion, relayer)

	core.EmitChannelOpenAck(0, rlm, portId, msg.ChannelId, updated, connection)
}

// ChannelOpenConfirm proves the counterparty Open and moves the local TryOpen
// channel to Open, notifying its app.
func (c *coreV1) ChannelOpenConfirm(_ int, rlm realm, msg types.MsgChannelOpenConfirm) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenConfirm(0, rlm, msg, true)
}

// ForceChannelOpenConfirm is the admin recovery variant of ChannelOpenConfirm
// that skips counterparty proof verification.
func (c *coreV1) ForceChannelOpenConfirm(_ int, rlm realm, msg types.MsgChannelOpenConfirm) {
	assertIsRlmCurrent(0, rlm)

	c.channelOpenConfirm(0, rlm, msg, false)
}

func (c *coreV1) channelOpenConfirm(_ int, rlm realm, msg types.MsgChannelOpenConfirm, verify bool) {
	relayer := rlm.Previous().Address()

	channel, err := c.getChannel(msg.ChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateTryOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	if channel.CounterpartyChannelId == 0 {
		panic(makeError(core.ErrInvalidCounterpartyChannelId))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)
	portId, _ := c.store.GetChannelOwner(msg.ChannelId)

	if verify {
		expectedChannel := core.NewChannel(
			types.ChannelStateOpen,
			connection.CounterpartyConnectionId,
			msg.ChannelId,
			portId,
			channel.Version,
		)
		key := types.ChannelPath(channel.CounterpartyChannelId)
		value := core.ChannelValue(expectedChannel)
		c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.ProofAck, key[:], value[:])
	}

	updated := core.NewChannel(
		types.ChannelStateOpen,
		channel.ConnectionId,
		channel.CounterpartyChannelId,
		channel.CounterpartyPortId.Clone(),
		channel.Version,
	)
	c.store.SaveChannel(0, rlm, msg.ChannelId, updated)

	a, err := c.getAppAtPort(portId)
	if err != nil {
		panic(err)
	}

	a.OnChannelOpenConfirm(cross(rlm), msg.ChannelId, relayer)

	core.EmitChannelOpenConfirm(0, rlm, portId, msg.ChannelId, updated, connection)
}

// ChannelCloseInit closes an Open channel locally and notifies its app.
func (c *coreV1) ChannelCloseInit(_ int, rlm realm, msg types.MsgChannelCloseInit) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()

	channel, err := c.getChannel(msg.ChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	if channel.CounterpartyChannelId == 0 {
		panic(makeError(core.ErrInvalidCounterpartyChannelId))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)
	portId, _ := c.store.GetChannelOwner(msg.ChannelId)

	updated := c.closedChannel(channel)
	c.store.SaveChannel(0, rlm, msg.ChannelId, updated)

	a, ok := c.store.GetAppByPortId(portId)
	if !ok {
		panic("port " + string(portId) + " not found")
	}
	a.OnChannelCloseInit(cross(rlm), msg.ChannelId, relayer)
	core.EmitChannelCloseInit(0, rlm, portId, msg.ChannelId, updated, connection)
}

// ChannelCloseConfirm proves the counterparty Closed and closes the local
// channel, notifying its app.
func (c *coreV1) ChannelCloseConfirm(_ int, rlm realm, msg types.MsgChannelCloseConfirm) {
	assertIsRlmCurrent(0, rlm)

	relayer := rlm.Previous().Address()

	channel, err := c.getChannel(msg.ChannelId)
	if err != nil {
		panic(err)
	}

	if channel.State != types.ChannelStateOpen {
		panic(makeError(core.ErrInvalidChannelState))
	}

	if channel.CounterpartyChannelId == 0 {
		panic(makeError(core.ErrInvalidCounterpartyChannelId))
	}

	connection := c.ensureConnectionState(channel.ConnectionId)
	portId, _ := c.store.GetChannelOwner(msg.ChannelId)

	expectedChannel := core.NewChannel(
		types.ChannelStateClosed,
		connection.CounterpartyConnectionId,
		msg.ChannelId,
		portId,
		channel.Version,
	)
	key := types.ChannelPath(channel.CounterpartyChannelId)
	value := core.ChannelValue(expectedChannel)
	c.verifyMembership(connection.ClientId, types.NewHeight(msg.ProofHeight), msg.ProofInit, key[:], value[:])

	updated := c.closedChannel(channel)
	c.store.SaveChannel(0, rlm, msg.ChannelId, updated)

	a, ok := c.store.GetAppByPortId(portId)
	if !ok {
		panic("port " + string(portId) + " not found")
	}
	a.OnChannelCloseConfirm(cross(rlm), msg.ChannelId, relayer)
	core.EmitChannelCloseConfirm(0, rlm, portId, msg.ChannelId, updated, connection)
}

// closedChannel returns a Closed copy of channel without mutating the store-owned
// value.
func (c *coreV1) closedChannel(channel types.Channel) types.Channel {
	return core.NewChannel(
		types.ChannelStateClosed,
		channel.ConnectionId,
		channel.CounterpartyChannelId,
		channel.CounterpartyPortId.Clone(),
		channel.Version,
	)
}

// getChannel returns the stored channel for channelId, or an error when it is
// missing. It centralizes the lookup shared by the handshake and packet paths;
// the caller (entrypoint) decides whether a miss reverts.
func (c *coreV1) getChannel(channelId types.ChannelId) (types.Channel, error) {
	channel, ok := c.store.GetChannel(channelId)
	if !ok {
		return types.Channel{}, makeError(core.ErrChannelNotFound, channelId.String())
	}

	return channel, nil
}
