package pgbig
import "gno.land/p/nt/ufmt/v0"
var data [100]string
func init() { for i := 0; i < 100; i++ { data[i] = ufmt.Sprintf("gnome-%d-with-some-padding-text-to-make-it-bigger", i) } }
func Render(path string) string { return data[0] }
