package gettime

import "time"

func GetTimeNow() int64 {
	return time.Now().UnixMilli()
}