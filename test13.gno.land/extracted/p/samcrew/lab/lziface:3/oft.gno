package lziface

import (
	"encoding/binary"

	"gno.land/p/samcrew/deps/onbloc/uint256"
)

const OFT_SEND_TO_OFFSET = 32
const OFT_SEND_AMOUNT_SD_OFFSET = 40

type OFTMsg []byte

func OFTMsgEncode(to [32]byte, amountSD uint64, composeMsg []byte) ([]byte, bool) {
	res := make([]byte, OFT_SEND_AMOUNT_SD_OFFSET+len(composeMsg))
	copy(res, to[:])
	binary.BigEndian.PutUint64(res[OFT_SEND_TO_OFFSET:], amountSD)
	copy(res[OFT_SEND_AMOUNT_SD_OFFSET:], composeMsg)
	return res, len(composeMsg) != 0
}

/**
 * @dev Checks if the OFT message is composed.
 * @param _msg The OFT message.
 * @return A boolean indicating whether the message is composed.
 */
func (msg OFTMsg) IsComposed() bool {
	return len(msg) > OFT_SEND_AMOUNT_SD_OFFSET
}

/**
 * @dev Retrieves the recipient address from the OFT message.
 * @param _msg The OFT message.
 * @return The recipient address.
 */
func (msg OFTMsg) SendTo() [32]byte {
	res := [32]byte{}
	copy(res[:], msg)
	return res
}

/**
 * @dev Retrieves the amount in shared decimals from the OFT message.
 * @param _msg The OFT message.
 * @return The amount in shared decimals.
 */
func (msg OFTMsg) AmountSD() uint64 {
	return binary.BigEndian.Uint64(msg[OFT_SEND_TO_OFFSET:])
}

/**
 * @dev Retrieves the composed message from the OFT message.
 * @param _msg The OFT message.
 * @return The composed message.
 */
func (msg OFTMsg) ComposeMsg() []byte {
	return msg[OFT_SEND_AMOUNT_SD_OFFSET:]
}

/**
 * @dev Struct representing OFT receipt information.
 */
type OFTReceipt struct {
	AmountSentLD *uint256.Uint // Amount of tokens ACTUALLY debited from the sender in local decimals.
	// @dev In non-default implementations, the amountReceivedLD COULD differ from this value.
	AmountReceivedLD *uint256.Uint // Amount of tokens to be received on the remote side.
}
