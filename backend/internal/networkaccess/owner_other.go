//go:build !windows

package networkaccess

func describePortOwners(address string, port int) []PortOwner { return nil }
