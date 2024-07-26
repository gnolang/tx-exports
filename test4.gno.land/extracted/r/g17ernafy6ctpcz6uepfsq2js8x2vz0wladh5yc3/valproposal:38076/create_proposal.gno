package valproposal

import (
    "std"

    pVals "gno.land/p/sys/validators"
    govdao "gno.land/r/gov/dao"
    "gno.land/r/sys/validators"
)

func init() {
    changesFn := func() []pVals.Validator {
        return []pVals.Validator{
            {
                Address:     std.Address("g1rncfld0c9r0gzkzr9mjary5fr3sseass6ag3lf"),
                PubKey:      "l0XwzXPqilbq54k7lUzIT4hJTUxva2TMrYVGJGyEjsc=",
                VotingPower: 1, // leave this at 1
            },
        }
    }

    // Create the executor with the changes
    executor := validators.NewPropExecutor(changesFn)

    // Create a descriptive comment, you can use Markdown
    comment := "Proposal to add IrreverentSimplicity validator. Contributions can be found at: https://gno.flippando.xyz, https://gno.zentasktic.com"

    // Propose the changes to the govdao
    govdao.Propose(comment, executor)
}
