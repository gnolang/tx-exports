package bolo

// adminAddr is Bolo's admin (API §3.6): a constant in source, never the deployer.
//
// Until the real admin key exists, it is an address nobody holds a key for, so a
// deployment made by mistake has no admin at all. Tests and local runs stage the
// realm with a test admin instead (internal/stage).
const adminAddr address = "g1at2h7kdhz2m9lv6azn54mwu4wl95k94wu90uwj"
