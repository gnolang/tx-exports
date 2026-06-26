package block

import "strconv"

const (
	MigrationResearchExpectedBlockType      = "migration_research"
	MigrationResearchExpectedLayer          = "solid"
	MigrationResearchExpectedDrawType       = "cube"
	MigrationResearchExpectedTextureLayer   = "default"
	MigrationResearchExpectedTextureURL     = "migration_texture"
	MigrationResearchExpectedPreviewURL     = "migration_preview"
	MigrationResearchExpectedOption         = "migration_option"
	MigrationResearchExpectedContent        = "migration_content"
	MigrationResearchExpectedUpdatedOption  = "exercise_option"
	MigrationResearchExpectedPersonalWorld  = "1"
	MigrationResearchExpectedSystemWorld    = "4000000001"
	MigrationResearchExpectedPersonalPosIdx = "100"
	MigrationResearchExpectedSystemPosIdx   = "101"
	MigrationResearchExpectedMintAmount     = int64(3)
)

func migrationResearchPersonalPosition(owner address) string {
	return "personal|" + MigrationResearchExpectedPersonalWorld + "|" + owner.String() + "|0|0|" + MigrationResearchExpectedPersonalPosIdx
}

func migrationResearchSystemPosition(owner address) string {
	return "system|" + MigrationResearchExpectedSystemWorld + "|" + owner.String() + "|0|1|" + MigrationResearchExpectedSystemPosIdx
}

func migrationResearchBlockPropKeys() string {
	return "name,blockType,layer,drawType,textureLayer,textureURL,previewURL,maxSupply,mintPrice,usePrice,installerBps,shape,state,emission"
}

func migrationResearchBlockPropValues(name string, maxSupply string, mintPrice string, usePrice string, installerBPS string, shape uint32, state uint32, emission uint8) string {
	return name + "," +
		MigrationResearchExpectedBlockType + "," +
		MigrationResearchExpectedLayer + "," +
		MigrationResearchExpectedDrawType + "," +
		MigrationResearchExpectedTextureLayer + "," +
		MigrationResearchExpectedTextureURL + "," +
		MigrationResearchExpectedPreviewURL + "," +
		maxSupply + "," +
		mintPrice + "," +
		usePrice + "," +
		installerBPS + "," +
		strconv.FormatUint(uint64(shape), 10) + "," +
		strconv.FormatUint(uint64(state), 10) + "," +
		strconv.FormatUint(uint64(emission), 10)
}
