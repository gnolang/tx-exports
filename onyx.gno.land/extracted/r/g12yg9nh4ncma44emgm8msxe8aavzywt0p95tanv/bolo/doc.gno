// Package bolo is Bolo's version registry (API §3.7): it tells clients which
// version new campaigns start on. Every version lives at its own path,
// gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/vN, and keeps its campaigns and their money for good (ADR
// D14); the registry holds no money and only points.
package bolo
