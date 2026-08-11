// Package app defines the IBC application callback contract that core invokes.
// The interface lives in a pure package so application realms can implement it
// without importing core, and core can route packets to them by interface
// (dependency inversion: app imports core, core depends only on this contract).
package app

import "gno.land/p/onbloc/ibc/union/types"

// IApp defines the interface for IBC application callbacks. Byte parameters
// use plain []byte (not the typed Bytes wrapper) so foreign-realm apps can
// implement the interface without the cross(cur)-realm typed-slice pitfall.
type IApp interface {
	OnChannelOpenInit(cur realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, relayer address)
	OnChannelOpenTry(cur realm, connectionId types.ConnectionId, channelId types.ChannelId, version string, counterpartyVersion string, relayer address)
	OnChannelOpenAck(cur realm, channelId types.ChannelId, counterpartyChannelId types.ChannelId, counterpartyVersion string, relayer address)
	OnChannelOpenConfirm(cur realm, channelId types.ChannelId, relayer address)
	OnChannelCloseInit(cur realm, channelId types.ChannelId, relayer address)
	OnChannelCloseConfirm(cur realm, channelId types.ChannelId, relayer address)
	OnRecvPacket(cur realm, packet types.Packet, relayer address, relayerMsg []byte) types.RecvPacketResult
	OnAcknowledgementPacket(cur realm, packet types.Packet, acknowledgement []byte, relayer address)
	OnTimeoutPacket(cur realm, packet types.Packet, relayer address)

	IIntentApp
}

// IIntentApp is implemented by apps that explicitly support the proofless
// market-maker intent receive path.
type IIntentApp interface {
	OnIntentRecvPacket(cur realm, packet types.Packet, marketMaker address, marketMakerMsg []byte) types.RecvPacketResult
}
