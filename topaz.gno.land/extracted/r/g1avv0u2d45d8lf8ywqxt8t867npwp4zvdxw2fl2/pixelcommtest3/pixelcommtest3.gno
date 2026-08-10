package pixelcommtest3

import (
	"strconv"
	"strings"

	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	MaxCommunityDesignPixels  = 4000
	MaxCommunityDesignNameLen = 60
)

const collectionOwner address = "g1avv0u2d45d8lf8ywqxt8t867npwp4zvdxw2fl2"

var (
	communityDesigns     avl.Tree
	communityDesignNames avl.Tree
	communityDesignCount int64

	palette = []string{"#000000", "#ffffff"}
)

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("owner-only")
	}
}

func SubmitCommunityDesign(cur realm, name string, encoded string) string {
	runtime.AssertOriginCall()
	if len(name) > MaxCommunityDesignNameLen {
		panic(ufmt.Sprintf("name too long: max %d characters", MaxCommunityDesignNameLen))
	}
	if encoded == "" {
		panic("empty design")
	}
	entries := strings.Split(encoded, ";")
	if len(entries) > MaxCommunityDesignPixels {
		panic(ufmt.Sprintf("design too large: %d pixels, max %d", len(entries), MaxCommunityDesignPixels))
	}
	id := "d" + strconv.FormatInt(communityDesignCount, 10)
	communityDesignCount++
	communityDesigns.Set(id, encoded)
	communityDesignNames.Set(id, name)
	return id
}

func ListCommunityDesigns() string {
	var b strings.Builder
	for i := int64(0); i < communityDesignCount; i++ {
		id := "d" + strconv.FormatInt(i, 10)
		encoded, ok := communityDesigns.Get(id).(string)
		if !ok {
			continue
		}
		name, _ := communityDesignNames.Get(id).(string)
		count := len(strings.Split(encoded, ";"))
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(id + "," + name + "," + strconv.FormatInt(int64(count), 10))
	}
	return b.String()
}

func GetCommunityDesign(id string) string {
	encoded, _ := communityDesigns.Get(id).(string)
	return encoded
}

func RemoveCommunityDesign(cur realm, id string) {
	assertOwner()
	communityDesigns.Remove(id)
	communityDesignNames.Remove(id)
}

func Render(path string) string { return "ok" }
