package grc721v2

import (
	"chain"
	unsaferealm "chain/runtime/unsafe"
	"math/overflow"
	"strconv"

	"gno.land/p/g1wx60nkcp5lfsxmedeg7sfs47tzxkath05u63t4/avl"
	"gno.land/p/nt/ufmt/v0"
)

type BasicNFT struct {
	name              string
	symbol            string
	origRealm         string   // owning realm's package path
	owners            avl.Tree // tokenId -> OwnerAddress
	balances          avl.Tree // OwnerAddress -> TokenCount
	tokenApprovals    avl.Tree // TokenId -> ApprovedAddress
	tokenURIs         avl.Tree // TokenId -> URIs
	operatorApprovals avl.Tree // "OwnerAddress:OperatorAddress" -> bool
}

func NewBasicNFT(_ int, _ realm, name, symbol string) *BasicNFT {
	pkgPath := unsaferealm.CurrentRealm().PkgPath()
	if pkgPath == "" {
		panic(ErrNotRealm)
	}
	if !validName(name) {
		panic(ErrInvalidName)
	}
	if !validSymbol(symbol) {
		panic(ErrInvalidSymbol)
	}

	return &BasicNFT{
		name:      name,
		symbol:    symbol,
		origRealm: pkgPath,

		owners:            avl.Tree{},
		balances:          avl.Tree{},
		tokenApprovals:    avl.Tree{},
		tokenURIs:         avl.Tree{},
		operatorApprovals: avl.Tree{},
	}
}

func (s *BasicNFT) Name() string      { return s.name }
func (s *BasicNFT) Symbol() string    { return s.symbol }
func (s *BasicNFT) TokenCount() int64 { return int64(s.owners.Size()) }

func (s *BasicNFT) ID() string {
	return s.origRealm + "." + s.symbol
}

func (s *BasicNFT) BalanceOf(addr address) (int64, error) {
	if err := isValidAddress(addr); err != nil {
		return 0, err
	}

	balance := s.balances.Get(addr.String())
	if balance == nil {
		return 0, nil
	}

	return balance.(int64), nil
}

func (s *BasicNFT) OwnerOf(tid TokenID) (address, error) {
	owner := s.owners.Get(string(tid))
	if owner == nil {
		return "", ErrInvalidTokenId
	}

	return owner.(address), nil
}

func (s *BasicNFT) TokenURI(tid TokenID) (string, error) {
	uri := s.tokenURIs.Get(tid.String())
	if uri == nil {
		return "", ErrInvalidTokenId
	}

	return uri.(string), nil
}

func (s *BasicNFT) SetTokenURI(caller address, tid TokenID, tURI TokenURI) (bool, error) {
	if !s.exists(tid) {
		return false, ErrInvalidTokenId
	}

	owner, err := s.OwnerOf(tid)
	if err != nil {
		return false, err
	}
	if caller != owner {
		return false, ErrCallerIsNotOwner
	}
	s.tokenURIs.Set(tid.String(), tURI.String())

	chain.Emit(
		TokenURIUpdateEvent,
		"token", s.ID(),
		"tokenId", tid.String(),
	)

	return true, nil
}

func (s *BasicNFT) IsApprovedForAll(owner, operator address) bool {
	key := owner.String() + ":" + operator.String()
	approved := s.operatorApprovals.Get(key)
	if approved == nil {
		return false
	}

	return approved.(bool)
}

func (s *BasicNFT) Approve(caller, to address, tid TokenID) error {
	if err := isValidAddress(to); err != nil {
		return err
	}

	owner, err := s.OwnerOf(tid)
	if err != nil {
		return err
	}
	if owner == to {
		return ErrApprovalToCurrentOwner
	}

	if caller != owner && !s.IsApprovedForAll(owner, caller) {
		return ErrCallerIsNotOwnerOrApproved
	}

	tidStr := tid.String()
	s.tokenApprovals.Set(tidStr, to)

	chain.Emit(
		ApprovalEvent,
		"token", s.ID(),
		"owner", owner.String(),
		"to", to.String(),
		"tokenId", tidStr,
	)

	return nil
}

func (s *BasicNFT) GetApproved(tid TokenID) (address, error) {
	addr := s.tokenApprovals.Get(tid.String())
	if addr == nil {
		return zeroAddress, ErrTokenIdNotHasApproved
	}

	return addr.(address), nil
}

func (s *BasicNFT) SetApprovalForAll(caller, operator address, approved bool) error {
	if err := isValidAddress(operator); err != nil {
		return ErrInvalidAddress
	}
	return s.setApprovalForAll(caller, operator, approved)
}

func (s *BasicNFT) SafeTransferFrom(caller, from, to address, tid TokenID) error {
	if !s.isApprovedOrOwner(caller, tid) {
		return ErrCallerIsNotOwnerOrApproved
	}

	err := s.transfer(from, to, tid)
	if err != nil {
		return err
	}

	if !s.checkOnGRC721Received(from, to, tid) {
		return ErrTransferToNonGRC721Receiver
	}

	return nil
}

func (s *BasicNFT) TransferFrom(caller, from, to address, tid TokenID) error {
	if !s.isApprovedOrOwner(caller, tid) {
		return ErrCallerIsNotOwnerOrApproved
	}

	err := s.transfer(from, to, tid)
	if err != nil {
		return err
	}

	return nil
}

func (s *BasicNFT) Mint(to address, tid TokenID) error {
	return s.mint(to, tid)
}

func (s *BasicNFT) SafeMint(to address, tid TokenID) error {
	err := s.mint(to, tid)
	if err != nil {
		return err
	}

	if !s.checkOnGRC721Received(zeroAddress, to, tid) {
		return ErrTransferToNonGRC721Receiver
	}

	return nil
}

func (s *BasicNFT) Burn(tid TokenID) error {
	owner, err := s.OwnerOf(tid)
	if err != nil {
		return err
	}

	s.beforeTokenTransfer(owner, zeroAddress, tid, 1)

	tidStr := tid.String()
	s.tokenApprovals.Remove(tidStr)
	balance, err := s.BalanceOf(owner)
	if err != nil {
		return err
	}
	balance = overflow.Sub64p(balance, 1)

	ownerStr := owner.String()
	s.balances.Set(ownerStr, balance)
	s.owners.Remove(tidStr)

	chain.Emit(
		BurnEvent,
		"token", s.ID(),
		"from", ownerStr,
		"tokenId", tidStr,
	)

	s.afterTokenTransfer(owner, zeroAddress, tid, 1)

	return nil
}

func (s *BasicNFT) setApprovalForAll(owner, operator address, approved bool) error {
	if owner == operator {
		return ErrApprovalToCurrentOwner
	}

	key := owner.String() + ":" + operator.String()
	s.operatorApprovals.Set(key, approved)

	chain.Emit(
		ApprovalForAllEvent,
		"token", s.ID(),
		"owner", owner.String(),
		"to", operator.String(),
		"approved", strconv.FormatBool(approved),
	)

	return nil
}

func (s *BasicNFT) transfer(from, to address, tid TokenID) error {
	if err := isValidAddress(from); err != nil {
		return ErrInvalidAddress
	}
	if err := isValidAddress(to); err != nil {
		return ErrInvalidAddress
	}

	if from == to {
		return ErrCannotTransferToSelf
	}

	owner, err := s.OwnerOf(tid)
	if err != nil {
		return err
	}
	if owner != from {
		return ErrTransferFromIncorrectOwner
	}

	s.beforeTokenTransfer(from, to, tid, 1)

	owner, err = s.OwnerOf(tid)
	if err != nil {
		return err
	}
	if owner != from {
		return ErrTransferFromIncorrectOwner
	}

	tidStr := tid.String()
	s.tokenApprovals.Remove(tidStr)
	fromBalance, err := s.BalanceOf(from)
	if err != nil {
		return err
	}
	toBalance, err := s.BalanceOf(to)
	if err != nil {
		return err
	}
	fromBalance = overflow.Sub64p(fromBalance, 1)
	toBalance = overflow.Add64p(toBalance, 1)

	fromStr := from.String()
	toStr := to.String()

	s.balances.Set(fromStr, fromBalance)
	s.balances.Set(toStr, toBalance)
	s.owners.Set(tidStr, to)

	chain.Emit(
		TransferEvent,
		"token", s.ID(),
		"from", fromStr,
		"to", toStr,
		"tokenId", tidStr,
	)

	s.afterTokenTransfer(from, to, tid, 1)

	return nil
}

func (s *BasicNFT) mint(to address, tid TokenID) error {
	if err := isValidAddress(to); err != nil {
		return err
	}

	if s.exists(tid) {
		return ErrTokenIdAlreadyExists
	}

	s.beforeTokenTransfer(zeroAddress, to, tid, 1)

	if s.exists(tid) {
		return ErrTokenIdAlreadyExists
	}

	toBalance, err := s.BalanceOf(to)
	if err != nil {
		return err
	}
	toBalance = overflow.Add64p(toBalance, 1)
	toStr := to.String()
	tidStr := tid.String()
	s.balances.Set(toStr, toBalance)
	s.owners.Set(tidStr, to)

	chain.Emit(
		MintEvent,
		"token", s.ID(),
		"to", toStr,
		"tokenId", tidStr,
	)

	s.afterTokenTransfer(zeroAddress, to, tid, 1)

	return nil
}

func (s *BasicNFT) isApprovedOrOwner(addr address, tid TokenID) bool {
	owner := s.owners.Get(tid.String())
	if owner == nil {
		return false
	}

	ownerAddr := owner.(address)
	if addr == ownerAddr || s.IsApprovedForAll(ownerAddr, addr) {
		return true
	}

	approved, err := s.GetApproved(tid)
	if err != nil {
		return false
	}

	return approved == addr
}

func (s *BasicNFT) exists(tid TokenID) bool {
	return s.owners.Has(tid.String())
}

func (s *BasicNFT) beforeTokenTransfer(from, to address, firstTokenId TokenID, batchSize int64) {
}

func (s *BasicNFT) afterTokenTransfer(from, to address, firstTokenId TokenID, batchSize int64) {
}

func (s *BasicNFT) checkOnGRC721Received(from, to address, tid TokenID) bool {
	return true
}

func (s *BasicNFT) RenderHome() (str string) {
	str += ufmt.Sprintf("# %s ($%s)\n\n", s.name, s.symbol)
	str += ufmt.Sprintf("* **Total supply**: %d\n", s.TokenCount())
	str += ufmt.Sprintf("* **Known accounts**: %d\n", s.balances.Size())

	return
}

func (n *BasicNFT) Getter() NFTGetter {
	return func() IGRC721Reader {
		return n
	}
}
