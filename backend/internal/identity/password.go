package identity

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"golang.org/x/crypto/argon2"
	"strings"
	"unicode/utf8"
)

func passwordHash(password string) (string, error) {
	return passwordHashWithMinimum(password, 7)
}

func passwordHashWithMinimum(password string, minimum int) (string, error) {
	if utf8.RuneCountInString(password) < minimum || utf8.RuneCountInString(password) > 128 || len(password) > 1024 {
		return "", fmt.Errorf("密码须为%d–128个字符", minimum)
	}
	common := []string{"123456789012345", "passwordpassword", "1234567890123456", "qwertyuiopasdfgh", "administrator123", "password123456789"}
	for _, p := range common {
		if strings.EqualFold(password, p) {
			return "", fmt.Errorf("请勿使用常见密码")
		}
	}
	if strings.Count(password, string([]rune(password)[0])) == utf8.RuneCountInString(password) {
		return "", fmt.Errorf("请勿使用重复字符密码")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	hash := argon2.IDKey([]byte(password), salt, 3, 64*1024, 1, 32)
	return "a2id-v1$" + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(hash), nil
}

// PasswordMinimum describes this service's configured policy to every client.
func (s *Service) PasswordMinimum() int {
	if s.localPasswords {
		return 5
	}
	return 7
}

func (s *Service) passwordHash(password string) (string, error) {
	return passwordHashWithMinimum(password, s.PasswordMinimum())
}
func passwordMatches(encoded, password string) bool {
	if len(password) > 1024 {
		return false
	}
	p := strings.Split(encoded, "$")
	if len(p) != 3 || p[0] != "a2id-v1" {
		return false
	}
	salt, e := base64.RawStdEncoding.DecodeString(p[1])
	if e != nil || len(salt) != 16 {
		return false
	}
	want, e := base64.RawStdEncoding.DecodeString(p[2])
	if e != nil || len(want) != 32 {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, 3, 64*1024, 1, 32)
	return subtle.ConstantTimeCompare(got, want) == 1
}
