package cockpit

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
)

type storedWeather struct {
	Host   string `json:"host"`
	Secret string `json:"secret,omitempty"`
}

func (s *Service) weatherFields(saved *storedWeather) (host string, hasKey bool) {
	if saved == nil {
		return s.weatherHost, validWeatherHost(s.weatherHost) && s.weatherKey != ""
	}
	return saved.Host, saved.Secret != ""
}

func (s *Service) changeWeather(saved *storedWeather, host, apiKey *string) (*storedWeather, error) {
	current, _ := s.weatherFields(saved)
	next := current
	if host != nil {
		next = strings.ToLower(strings.TrimSpace(*host))
	}
	if apiKey == nil && next == current {
		return saved, nil
	}
	if next == "" && apiKey == nil {
		return &storedWeather{}, nil
	}
	if !validWeatherHost(next) {
		return nil, errors.New("请输入和风控制台的完整 API Host 域名")
	}
	if apiKey == nil {
		return nil, errors.New("更换和风域名时请填写该账号的 API KEY")
	}
	key := strings.TrimSpace(*apiKey)
	if len(key) == 0 || len(key) > 256 || strings.IndexFunc(key, func(r rune) bool {
		return r <= ' ' || r > '~'
	}) >= 0 {
		return nil, errors.New("请输入有效的和风 API KEY")
	}
	if s.weatherCipher == nil {
		return nil, errors.New("天气密钥存储不可用")
	}
	nonce := make([]byte, s.weatherCipher.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	sealed := s.weatherCipher.Seal(nonce, nonce, []byte(key), []byte(next))
	return &storedWeather{Host: next, Secret: base64.StdEncoding.EncodeToString(sealed)}, nil
}

func (s *Service) weatherCredential(saved *storedWeather) (string, error) {
	if saved == nil {
		return s.weatherKey, nil
	}
	if s.weatherCipher == nil {
		return "", errors.New("天气密钥存储不可用")
	}
	raw, err := base64.StdEncoding.DecodeString(saved.Secret)
	n := s.weatherCipher.NonceSize()
	if err == nil && len(raw) >= n+s.weatherCipher.Overhead() {
		plain, err := s.weatherCipher.Open(nil, raw[:n], raw[n:], []byte(saved.Host))
		if err == nil {
			return string(plain), nil
		}
	}
	return "", errors.New("和风密钥无法读取，请在驾驶舱配置中重新填写")
}
