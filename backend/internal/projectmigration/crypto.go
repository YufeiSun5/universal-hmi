package projectmigration

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"

	"golang.org/x/crypto/argon2"
)

const magic = "HMI-MIGRATION-1\n"
const chunkSize = 1024 * 1024

var errArchive = errors.New("迁移包损坏、格式不受支持或密码不正确")

// Every record authenticates its position and the archive header. An encrypted
// empty final record is mandatory, so truncation and record reordering fail.
type sealedWriter struct {
	out    io.Writer
	aead   cipher.AEAD
	header []byte
	seq    uint64
	buf    []byte
}

func key(password string, salt []byte) (cipher.AEAD, error) {
	derived := argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, 32)
	block, err := aes.NewCipher(derived)
	clear(derived)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func newSealedWriter(out io.Writer, password string) (*sealedWriter, error) {
	header := make([]byte, len(magic)+16)
	copy(header, magic)
	if _, err := rand.Read(header[len(magic):]); err != nil {
		return nil, err
	}
	aead, err := key(password, header[len(magic):])
	if err != nil {
		return nil, err
	}
	if _, err = out.Write(header); err != nil {
		return nil, err
	}
	return &sealedWriter{out: out, aead: aead, header: header}, nil
}

func (w *sealedWriter) record(data []byte) error {
	nonce := make([]byte, w.aead.NonceSize())
	binary.BigEndian.PutUint64(nonce[len(nonce)-8:], w.seq)
	w.seq++
	sealed := w.aead.Seal(nil, nonce, data, w.header)
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(sealed)))
	if _, err := w.out.Write(size[:]); err != nil {
		return err
	}
	_, err := w.out.Write(sealed)
	return err
}

func (w *sealedWriter) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 {
		take := min(len(p), chunkSize-len(w.buf))
		w.buf = append(w.buf, p[:take]...)
		p = p[take:]
		if len(w.buf) == chunkSize {
			if err := w.record(w.buf); err != nil {
				return 0, err
			}
			w.buf = w.buf[:0]
		}
	}
	return n, nil
}

func (w *sealedWriter) Close() error {
	if len(w.buf) > 0 {
		if err := w.record(w.buf); err != nil {
			return err
		}
	}
	clear(w.buf)
	w.buf = nil
	return w.record(nil)
}

type sealedReader struct {
	in     io.Reader
	aead   cipher.AEAD
	header []byte
	seq    uint64
	buf    []byte
	done   bool
}

func newSealedReader(in io.Reader, password string) (*sealedReader, error) {
	header := make([]byte, len(magic)+16)
	if _, err := io.ReadFull(in, header); err != nil || !bytes.Equal(header[:len(magic)], []byte(magic)) {
		return nil, errArchive
	}
	aead, err := key(password, header[len(magic):])
	if err != nil {
		return nil, err
	}
	return &sealedReader{in: in, aead: aead, header: header}, nil
}

func (r *sealedReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(r.buf) > 0 {
		n := copy(p, r.buf)
		r.buf = r.buf[n:]
		return n, nil
	}
	if r.done {
		return 0, io.EOF
	}
	var size [4]byte
	if _, err := io.ReadFull(r.in, size[:]); err != nil {
		return 0, errArchive
	}
	n := binary.BigEndian.Uint32(size[:])
	if n < uint32(r.aead.Overhead()) || n > chunkSize+uint32(r.aead.Overhead()) {
		return 0, errArchive
	}
	data := make([]byte, n)
	if _, err := io.ReadFull(r.in, data); err != nil {
		return 0, errArchive
	}
	nonce := make([]byte, r.aead.NonceSize())
	binary.BigEndian.PutUint64(nonce[len(nonce)-8:], r.seq)
	r.seq++
	plain, err := r.aead.Open(nil, nonce, data, r.header)
	if err != nil {
		return 0, errArchive
	}
	if len(plain) == 0 {
		var extra [1]byte
		if n, err := r.in.Read(extra[:]); n != 0 || err != io.EOF {
			return 0, errArchive
		}
		r.done = true
		return 0, io.EOF
	}
	r.buf = plain
	return r.Read(p)
}
