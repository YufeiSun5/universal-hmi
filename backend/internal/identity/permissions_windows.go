package identity

import (
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
)

// Windows ignores Unix mode bits. Protect the security store and its known
// files with an inheritable DACL for the service account and LocalSystem.
func protectStore(dir string) error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;" + user.User.Sid.String() + ")(A;OICI;FA;;;SY)")
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	for _, name := range []string{"", "identity.db", "identity.db-wal", "identity.db-shm", "mfa.key"} {
		path := filepath.Join(dir, name)
		if _, err = os.Lstat(path); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return err
		}
		if err = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
			return err
		}
	}
	return nil
}
