package lziface

import (
	"encoding/binary"
)

// GnoPacket represents a LayerZero message packet originating from gno
type GnoPacket struct {
	Nonce      uint64      // uint64 in Solidity
	SrcEid     uint32      // uint32 in Solidity
	SenderAddr address // address in Solidity
	DstEid     uint32      // uint32 in Solidity
	Receiver   [32]byte    // bytes32 in Solidity
	GUID       [32]byte    // bytes32 in Solidity
	Message    []byte      // bytes in Solidity
}

func (p *GnoPacket) Encode() []byte {
	bz := make([]byte, 1+8+4+32+4+32+32+len(p.Message))

	bz[0] = 1 // version

	binary.BigEndian.PutUint64(bz[1:], p.Nonce)

	binary.BigEndian.PutUint32(bz[1+8:], p.SrcEid)

	senderLzAddr := AddressToBytes32(p.SenderAddr)
	copy(bz[1+8+4:], senderLzAddr[:])

	binary.BigEndian.PutUint32(bz[1+8+4+32:], p.DstEid)

	copy(bz[1+8+4+32+4:], p.Receiver[:])

	copy(bz[81:], p.GUID[:])

	copy(bz[81+32:], p.Message)

	return bz
}

type Packet []byte

func (p Packet) Header() PacketHeader {
	return PacketHeader(p[:81])
}

func (p Packet) Payload() PacketPayload {
	return PacketPayload(p[81:])
}

type PacketHeader []byte

func (ph PacketHeader) Version() uint8 {
	return ph[0]
}

func (ph PacketHeader) Nonce() uint64 {
	return binary.BigEndian.Uint64(ph[1:])
}

func (ph PacketHeader) SrcEID() uint32 {
	return binary.BigEndian.Uint32(ph[9:])
}

func (ph PacketHeader) Sender() [32]byte {
	sender := [32]byte{}
	copy(sender[:], ph[13:])
	return sender
}

func (ph PacketHeader) DstEID() uint32 {
	return binary.BigEndian.Uint32(ph[45:])
}

func (ph PacketHeader) Receiver() [32]byte {
	receiver := [32]byte{}
	copy(receiver[:], ph[49:])
	return receiver
}

func (ph PacketHeader) ReceiverAddr() address {
	return Bytes32ToAddress(ph.Receiver())
}

func (ph PacketHeader) Origin() *Origin {
	return &Origin{
		SrcEID: ph.SrcEID(),
		Sender: ph.Sender(),
		Nonce:  ph.Nonce(),
	}
}

type PacketPayload []byte

func (ph PacketPayload) GUID() [32]byte {
	guid := [32]byte{}
	copy(guid[:], ph)
	return guid
}

func (ph PacketPayload) Message() []byte {
	return ph[32:]
}
