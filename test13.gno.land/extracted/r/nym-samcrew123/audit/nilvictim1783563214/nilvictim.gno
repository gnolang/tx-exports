package nilvictim

import nilhole "gno.land/p/g1hzlg063fqrq4gltql992ssjc0xzau89t5jp63w/audit/nilhole1783563214"

var gSlot = nilhole.Slot{Field: "original"}

func Attack() {
	nilhole.PDispatch.UseMutator(&gSlot, nilhole.EvilInt(0))
}

func GetField() string { return gSlot.Field }
