package materials

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"image"
	"image/jpeg"
	"image/png"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/disintegration/imaging"
)

const MaxImageBytes = 10 * 1024 * 1024

func normalizeImage(data []byte) ([]byte, string, error) {
	if len(data) == 0 || len(data) > MaxImageBytes {
		return nil, "", errors.New("图片不能为空且最多10 MiB")
	}
	cfg, format, e := image.DecodeConfig(bytes.NewReader(data))
	if e != nil || (format != "png" && format != "jpeg") {
		return nil, "", errors.New("请选择有效的JPEG或PNG图片")
	}
	if cfg.Width < 1 || cfg.Height < 1 || int64(cfg.Width)*int64(cfg.Height) > 20000000 {
		return nil, "", errors.New("图片不能超过2000万像素")
	}
	img, e := imaging.Decode(bytes.NewReader(data), imaging.AutoOrientation(true))
	if e != nil {
		return nil, "", errors.New("图片内容损坏")
	}
	var b bytes.Buffer
	if format == "png" {
		e = png.Encode(&b, img)
	} else {
		e = jpeg.Encode(&b, img, &jpeg.Options{Quality: 95})
	}
	if e != nil {
		return nil, "", e
	}
	if b.Len() > MaxImageBytes {
		return nil, "", errors.New("图片处理后超过10 MiB，请缩小图片")
	}
	return b.Bytes(), "image/" + format, nil
}
func (s *Service) Upload(ctx context.Context, in AssetInput) (Asset, error) {
	capability := "personal"
	if in.Kind == "receipt" {
		capability = "inbound"
	} else if in.Kind != "signature" {
		return Asset{}, invalid("图片类型")
	}
	if _, e := actor(ctx, capability); e != nil {
		return Asset{}, e
	}
	if !textValid(in.Name, 200, true) {
		return Asset{}, invalid("图片名称")
	}
	data, mime, e := normalizeImage(in.Data)
	if e != nil {
		return Asset{}, e
	}
	return mutate(ctx, s, capability, "asset", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Asset, error) {
		v := Asset{ID: id(), Name: in.Name, Kind: in.Kind, MIME: mime}
		_, e := tx.Exec("INSERT INTO materials_assets(id,owner_id,kind,body,data) VALUES(?,?,?,?,?)", v.ID, a.ID, v.Kind, raw(v), base64.StdEncoding.EncodeToString(data))
		return v, e
	})
}
func (s *Service) Signature(ctx context.Context) (Signature, error) {
	a, e := actor(ctx, "personal")
	if e != nil {
		return Signature{}, e
	}
	return signature(s.db, a.ID)
}
func (s *Service) SaveSignature(ctx context.Context, in SignatureInput) (Signature, error) {
	return mutate(ctx, s, "personal", "signature", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Signature, error) {
		old, e := signature(tx, a.ID)
		if e != nil {
			return old, e
		}
		if old.Version != in.Version {
			return old, ErrConflict
		}
		var owner, kind string
		if e = tx.QueryRow("SELECT owner_id,kind FROM materials_assets WHERE id=?", in.AssetID).Scan(&owner, &kind); e != nil {
			return old, ErrMissing
		}
		if owner != a.ID || kind != "signature" {
			return old, authorization.ErrDenied
		}
		v := Signature{AssetID: in.AssetID, Version: old.Version + 1}
		_, e = tx.Exec("INSERT INTO materials_signatures(user_id,asset_id,version) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET asset_id=excluded.asset_id,version=excluded.version", a.ID, v.AssetID, v.Version)
		return v, e
	})
}
func (s *Service) Asset(ctx context.Context, key string) (Asset, []byte, error) {
	a, e := actor(ctx, "personal")
	if e != nil {
		return Asset{}, nil, e
	}
	var owner, kind string
	if e = s.db.QueryRow("SELECT owner_id,kind FROM materials_assets WHERE id=?", key).Scan(&owner, &kind); e != nil {
		return Asset{}, nil, ErrMissing
	}
	if kind == "receipt" && !a.Grants.MaterialsInbound {
		return Asset{}, nil, ErrMissing
	}
	if owner != a.ID {
		var n int
		e = s.db.QueryRow(`SELECT COUNT(*) FROM materials_document_assets da JOIN materials_documents d ON d.id=da.document_id WHERE da.asset_id=? AND ((d.kind='inbound' AND ?=1) OR (d.kind IN ('outbound','return') AND ?=1))`, key, boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsOutbound)).Scan(&n)
		if e != nil {
			return Asset{}, nil, e
		}
		if n == 0 {
			e = s.db.QueryRow(`SELECT COUNT(*) FROM materials_application_signatures sa JOIN materials_applications ap ON ap.id=sa.application_id WHERE sa.asset_id=? AND (?=1 OR (?=1 AND ap.owner_id=?))`, key, boolInt(a.Grants.MaterialsApprove), boolInt(a.Grants.MaterialsRequest), a.ID).Scan(&n)
			if e != nil {
				return Asset{}, nil, e
			}
		}
		if n == 0 {
			return Asset{}, nil, ErrMissing
		}
	}
	return loadAsset(s.db, key)
}
func loadAsset(q queryer, key string) (Asset, []byte, error) {
	var v Asset
	var body, encoded string
	if e := q.QueryRow("SELECT body,data FROM materials_assets WHERE id=?", key).Scan(&body, &encoded); e != nil {
		return v, nil, e
	}
	if e := decodeBody(body, &v); e != nil {
		return v, nil, e
	}
	b, e := base64.StdEncoding.DecodeString(encoded)
	return v, b, e
}
