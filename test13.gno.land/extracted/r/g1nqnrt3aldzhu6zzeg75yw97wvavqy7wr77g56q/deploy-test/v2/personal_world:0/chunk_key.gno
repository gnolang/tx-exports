package personal_world

import (
	"strconv"
	"strings"
)

// formatWorldID converts a world ID to a string key for verifier storage lookups
func formatWorldID(worldID uint32) string {
	return strconv.FormatUint(uint64(worldID), 10)
}

// buildCoordKey builds "x_y" coordinate string
func buildCoordKey(x, y int) string {
	return strconv.Itoa(x) + "_" + strconv.Itoa(y)
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

// buildWorldChunkKey builds "worldID:x_y" from world and coord key.
func buildWorldChunkKey(worldID uint32, coordKey string) string {
	return formatWorldID(worldID) + ":" + coordKey
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
	return buildWorldChunkKey(worldID, buildCoordKey(x, y))
}
