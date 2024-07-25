./build/gnokey maketx call test1 --pkgpath "gno.land/r/demo/boards" --func CreateBoard --args "testboard" --gas-fee 1ugnot --gas-wanted 2000000 > createboard.unsigned.txt
./build/gnokey sign test1 --txpath createboard.unsigned.txt --chainid "test3" --number 0 --sequence 2 > createboard.signed.txt
./build/gnokey broadcast createboard.signed.txt --remote test3.gno.land:36657