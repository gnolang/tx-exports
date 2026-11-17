// Package e2ecanary is a throwaway realm proving an end-to-end publish on onyx.
package e2ecanary

// Render returns a fixed line naming the release and the submission time.
func Render(_ string) string {
	return "v1.8.0-rc.1 e2e 2026-11-17T15:57:18Z"
}
