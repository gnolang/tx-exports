// Package ipfstest renders one image linked as ipfs://, to check that gnoweb
// loads such links through its IPFS gateway.
package ipfstest

func Render(_ string) string {
	return "# IPFS gateway check\n\n" +
		"The image below is linked as `ipfs://`; gnoweb loads it through its gateway.\n\n" +
		"![Test image](ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi)\n"
}
