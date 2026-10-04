//go:build unix

package main

import (
	"os"
	"syscall"
)

// privateDir reports whether d is a real directory (not a symlink) owned by
// this user that no one else can enter.
func privateDir(d string) bool {
	fi, err := os.Lstat(d)
	if err != nil || !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 || fi.Mode().Perm()&0o077 != 0 {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}
