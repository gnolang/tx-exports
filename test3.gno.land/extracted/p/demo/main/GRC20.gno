package main

import (
	"fmt"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/x/bank"
)

type DisperseFundsContract struct {
	BankKeeper bank.Keeper
}

func NewDisperseFundsContract(bankKeeper bank.Keeper) *DisperseFundsContract {
	return &DisperseFundsContract{
		BankKeeper: bankKeeper,
	}
}

// DisperseFunds allows the contract owner to disperse funds to multiple recipients
func (dfc *DisperseFundsContract) DisperseFunds(ctx sdk.Context, owner sdk.AccAddress, recipients []sdk.AccAddress, amounts []sdk.Coins) error {
	// Check if the sender is the owner of the contract
	if !dfc.BankKeeper.GetCoins(ctx, owner).IsEqual(amounts[0]) {
		return fmt.Errorf("sender is not the owner of the contract")
	}

	// Loop through recipients and amounts to disperse funds
	for i, recipient := range recipients {
		// Check if the recipient account exists
		if dfc.BankKeeper.GetAccount(ctx, recipient) == nil {
			return fmt.Errorf("recipient account does not exist")
		}

		// Transfer funds from owner to recipient
		err := dfc.BankKeeper.SendCoins(ctx, owner, recipient, amounts[i])
		if err != nil {
			return fmt.Errorf("failed to disperse funds: %s", err.Error())
		}
	}

	return nil
}

func main() {
	// Initialize your Cosmos smart contract with the relevant dependencies (bank keeper, etc.)
	// For this example, assume you have access to the bank keeper
	bankKeeper := // your initialized bank keeper

	dfc := NewDisperseFundsContract(bankKeeper)

	// Example usage:
	ctx := // your initialized context
	owner := // the contract owner's address
	recipients := // array of recipient addresses
	amounts := // array of amounts to disperse

	err := dfc.DisperseFunds(ctx, owner, recipients, amounts)
	if err != nil {
		fmt.Printf("Error: %s\n", err.Error())
	} else {
		fmt.Println("Funds dispersed successfully.")
	}
}
