//go:build windows

package networkaccess

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// The address is a validated literal IPv4 and the port an integer. Only public
// process names/PIDs are returned; command lines and credentials never leave it.
func describePortOwners(address string, port int) []PortOwner {
	if !IsPrivateIPv4(address) || port < 1024 || port > 65535 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	script := fmt.Sprintf(`$ErrorActionPreference='Stop'; $owners=@(Get-NetTCPConnection -LocalPort %d -State Listen | Where-Object { $_.LocalAddress -in @('%s','0.0.0.0','::') } | Select-Object -ExpandProperty OwningProcess -Unique); $items=@(foreach($ownerId in $owners){$p=Get-Process -Id $ownerId -ErrorAction SilentlyContinue;if($p){[pscustomobject]@{pid=[int]$ownerId;program=$p.ProcessName}}}); ConvertTo-Json -InputObject $items -Compress`, port, address)
	command := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command", script)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	raw, err := command.Output()
	if err != nil {
		return nil
	}
	var owners []PortOwner
	if json.Unmarshal(raw, &owners) != nil {
		return nil
	}
	return owners
}
