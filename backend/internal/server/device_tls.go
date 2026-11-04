package server

import (
	"crypto/tls"
	"errors"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// PublicDeviceTLS clones the listener configuration. TLS verifies possession;
// the identity service authorizes an exact leaf on full and resumed handshakes.
// No client certificate continues through the separate Web IP policy.
func PublicDeviceTLS(base *tls.Config, service *identity.Service) (*tls.Config, error) {
	if base == nil || service == nil || base.VerifyConnection != nil || base.VerifyPeerCertificate != nil {
		return nil, errors.New("device TLS requires an independent listener configuration")
	}
	config := base.Clone()
	config.ClientAuth = tls.RequestClientCert
	config.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return nil
		}
		if len(state.PeerCertificates) != 1 {
			return errors.New("device TLS accepts one explicitly approved leaf")
		}
		_, err := service.VerifyDeviceCertificate(state.PeerCertificates[0])
		if err != nil {
			return service.VerifyDeviceBootstrap(state.PeerCertificates[0])
		}
		return err
	}
	return config, nil
}
