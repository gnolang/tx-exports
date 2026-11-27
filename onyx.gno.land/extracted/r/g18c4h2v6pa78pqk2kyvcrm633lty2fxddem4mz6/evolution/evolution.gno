package evolution

// 첫 번째 설계도: 펄서 창 + 프리즘 렌즈
func CanEvolve(weapon string, weaponLevel int, accessory string, accessoryLevel int) bool {
	return weapon == "pulsar_lance" &&
		weaponLevel == 10 &&
		accessory == "prism_lens" &&
		accessoryLevel == 8
}

func result(weaponLevel int, accessoryLevel int) string {
	if CanEvolve("pulsar_lance", weaponLevel, "prism_lens", accessoryLevel) {
		return "READY: Quasar Trident"
	}
	return "LOCKED"
}

func Render(path string) string {
	return "# GNOME SURVIVAL - Evolution Lab\n\n" +
		"* Pulsar Lance Lv10 + Prism Lens Lv7: " + result(10, 7) + "\n" +
		"* Pulsar Lance Lv10 + Prism Lens Lv8: " + result(10, 8) + "\n"
}
