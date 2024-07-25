// types.gno

package types

import (
	"errors"

	"gno.land/p/demo/avl"
)

var (
	gInt		int      	= -42
	gUint		uint    	= 42
	gString		string  	= "a string"
	gStringSlice	[]string	= []string{"a", "string", "slice"}
	gError		error   	= errors.New("an error")
	gIntSlice  	[]int    	= []int{-42, 0, 42}
	gUintSlice  	[]uint   	= []uint{0, 42, 84}
	gTree        	avl.Tree
)

func init() {
	gTree.Set("a", 	"a for alpha")
	gTree.Set("A", 	"A FOR ALPHA")
	gTree.Set("1", 	"1 for one")
	gTree.Set("b", 	"b for beta")
	gTree.Set("g", 	"g for gamma")
	gTree.Set("!", 	"! for !")
	gTree.Set("d", 	"d for delta")
	gTree.Set("%", 	"% for percent")
	gTree.Set("|", 	"| for pipeline")
}