package chunk

import (
	"strconv"
	"strings"
)

// formatWorldID converts a world ID to a string key for storage lookups
func formatWorldID(worldID uint32) string {
	return strconv.FormatUint(uint64(worldID), 10)
}

// buildChunkKey constructs the on-chain chunk key: "worldID:x_y"
func buildChunkKey(worldID uint32, x, y int) string {
	return strconv.FormatUint(uint64(worldID), 10) + ":" + strconv.Itoa(x) + "_" + strconv.Itoa(y)
}

// parseChunkKey parses "worldID:x_y" into (worldID, x, y)
func parseChunkKey(chunkKey string) (uint32, int, int) {
	parts := strings.SplitN(chunkKey, ":", 2)
	if len(parts) != 2 {
		panic("invalid chunkKey format: " + chunkKey)
	}

	worldID, err := strconv.ParseUint(parts[0], 10, 32)
	if err != nil {
		panic("invalid worldID in chunkKey: " + chunkKey)
	}

	coords := strings.SplitN(parts[1], "_", 2)
	if len(coords) != 2 {
		panic("invalid coordinates in chunkKey: " + chunkKey)
	}

	x, errX := strconv.Atoi(coords[0])
	if errX != nil {
		panic("invalid x in chunkKey: " + chunkKey)
	}

	y, errY := strconv.Atoi(coords[1])
	if errY != nil {
		panic("invalid y in chunkKey: " + chunkKey)
	}

	return uint32(worldID), x, y
}

// buildCoordKey builds "x_y" coordinate string
func buildCoordKey(x, y int) string {
	return strconv.Itoa(x) + "_" + strconv.Itoa(y)
}

// normalizeChunkKey validates and canonicalizes the required world prefix.
// Accepts only "worldID:x_y", returns canonical "worldID:x_y".
func normalizeChunkKey(worldID uint32, chunkKey string) string {
	if chunkKey == "" {
		panic("empty chunkKey not allowed")
	}

	colon := strings.Index(chunkKey, ":")
	if colon == -1 {
		panic("chunkKey must include worldID prefix: worldID:x_y")
	}

	keyWorldID := chunkKey[:colon]
	expected := formatWorldID(worldID)
	if keyWorldID != expected {
		panic("chunkKey worldID mismatch: expected " + expected + ", got " + keyWorldID)
	}
	coordKey := chunkKey[colon+1:]

	x, y := parseCoordKey(coordKey)
	return buildChunkKey(worldID, x, y)
}

// parseCoordKey parses "x_y" into (x, y)
func parseCoordKey(coordKey string) (int, int) {
	idx := strings.Index(coordKey, "_")
	if idx == -1 {
		panic("invalid coordKey: " + coordKey)
	}
	x, errX := strconv.Atoi(coordKey[:idx])
	if errX != nil {
		panic("invalid x in coordKey: " + coordKey)
	}
	y, errY := strconv.Atoi(coordKey[idx+1:])
	if errY != nil {
		panic("invalid y in coordKey: " + coordKey)
	}
	return x, y
}
