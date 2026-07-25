package types

import "gno.land/p/onbloc/access/manager"

const (
	RelayerSelectorRegisterClient        manager.Selector = "register_client"
	RelayerSelectorCreateClient          manager.Selector = "create_client"
	RelayerSelectorUpdateClient          manager.Selector = "update_client"
	RelayerSelectorMisbehaviour          manager.Selector = "misbehaviour"
	RelayerSelectorConnectionOpenInit    manager.Selector = "connection_open_init"
	RelayerSelectorConnectionOpenTry     manager.Selector = "connection_open_try"
	RelayerSelectorConnectionOpenAck     manager.Selector = "connection_open_ack"
	RelayerSelectorConnectionOpenConfirm manager.Selector = "connection_open_confirm"
	RelayerSelectorChannelOpenInit       manager.Selector = "channel_open_init"
	RelayerSelectorChannelOpenTry        manager.Selector = "channel_open_try"
	RelayerSelectorChannelOpenAck        manager.Selector = "channel_open_ack"
	RelayerSelectorChannelOpenConfirm    manager.Selector = "channel_open_confirm"
	RelayerSelectorBatchSend             manager.Selector = "batch_send"
	RelayerSelectorBatchAcks             manager.Selector = "batch_acks"
	RelayerSelectorPacketRecv            manager.Selector = "packet_recv"
	RelayerSelectorIntentPacketRecv      manager.Selector = "intent_packet_recv"
	RelayerSelectorPacketAck             manager.Selector = "packet_ack"
	RelayerSelectorPacketTimeout         manager.Selector = "packet_timeout"
)

func RelayerSelectors() []manager.Selector {
	return []manager.Selector{
		RelayerSelectorRegisterClient,
		RelayerSelectorCreateClient,
		RelayerSelectorUpdateClient,
		RelayerSelectorMisbehaviour,
		RelayerSelectorConnectionOpenInit,
		RelayerSelectorConnectionOpenTry,
		RelayerSelectorConnectionOpenAck,
		RelayerSelectorConnectionOpenConfirm,
		RelayerSelectorChannelOpenInit,
		RelayerSelectorChannelOpenTry,
		RelayerSelectorChannelOpenAck,
		RelayerSelectorChannelOpenConfirm,
		RelayerSelectorBatchSend,
		RelayerSelectorBatchAcks,
		RelayerSelectorPacketRecv,
		RelayerSelectorIntentPacketRecv,
		RelayerSelectorPacketAck,
		RelayerSelectorPacketTimeout,
	}
}
