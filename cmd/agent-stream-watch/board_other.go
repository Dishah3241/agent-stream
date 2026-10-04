//go:build !unix

package main

// privateDir is false where ownership cannot be checked: no sharing there.
func privateDir(string) bool { return false }
