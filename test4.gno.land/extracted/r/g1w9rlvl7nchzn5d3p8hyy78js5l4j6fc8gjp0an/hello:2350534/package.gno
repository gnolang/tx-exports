package hello

func Render(path string) string {
  return "Hello World!"
}

msg:0,success:false,log:--= Error =--
Data: vm.InvalidPkgPathError{abciError:vm.abciError{}}
Msg Traces:
    0  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/gno.land/pkg/sdk/vm/errors.go:44 - package already exists: gno.land/r/g1w9rlvl7nchzn5d3p8hyy78js5l4j6fc8gjp0an/hello
Stack Trace:
    0  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/errors/errors.go:20
    1  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/gno.land/pkg/sdk/vm/errors.go:44
    2  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/gno.land/pkg/sdk/vm/keeper.go:328
    3  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/gno.land/pkg/sdk/vm/handler.go:44
    4  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/gno.land/pkg/sdk/vm/handler.go:31
    5  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/sdk/baseapp.go:649
    6  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/sdk/baseapp.go:831
    7  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/sdk/baseapp.go:580
    8  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/abci/client/local_client.go:82
    9  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/appconn/app_conn.go:74
   10  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/state/execution.go:265
   11  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/state/execution.go:102
   12  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1370
   13  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1294
   14  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1240
   15  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1271
   16  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1684
   17  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:1518
   18  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:696
   19  /home/runner/go/pkg/mod/github.com/gnolang/gno@v0.2.0/tm2/pkg/bft/consensus/state.go:639
   20  /opt/hostedtoolcache/go/1.22.6/x64/src/runtime/asm_amd64.s:1695
--= /Error =--
,events:[]