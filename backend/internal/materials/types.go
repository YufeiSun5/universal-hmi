// Package materials owns the single-warehouse ledger, independently of HMI
// acquisition and physical control. All mutations use one database transaction.
package materials

import (
	"errors"
	"github.com/shopspring/decimal"
	"regexp"
)

var (
	ErrMissing   = errors.New("记录不存在或无查看权限")
	ErrConflict  = errors.New("内容或库存已变化，请刷新并重新确认")
	ErrStock     = errors.New("库存不足或退库数量超过剩余可退数量")
	ErrSignature = errors.New("请先在个人账号上传签名")
)

const maxUnits int64 = 999999999999999 // maximum scaled quantity; safe addition checks below
var numberPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,10})(\.[0-9]{1,4})?$`)

func units(value string, positive bool) (int64, error) {
	if !numberPattern.MatchString(value) {
		return 0, errors.New("请输入非负十进制数，最多11位整数和4位小数")
	}
	d, err := decimal.NewFromString(value)
	if err != nil {
		return 0, err
	}
	n := d.Shift(4).IntPart()
	if n > maxUnits || positive && n <= 0 {
		return 0, errors.New("数量必须大于0且不超出允许范围")
	}
	return n, nil
}
func quantity(n int64) string { return decimal.New(n, -4).String() }
func amount(n int64, price string) (string, error) {
	if price == "" {
		return "", nil
	}
	if _, e := units(price, false); e != nil {
		return "", e
	}
	d, e := decimal.NewFromString(price)
	if e != nil {
		return "", e
	}
	return decimal.New(n, -4).Mul(d).Round(2).StringFixed(2), nil
}

type Mutation struct {
	OperationID string `json:"operation_id"`
}
type Category struct {
	ID       string `json:"id"`
	ParentID string `json:"parent_id"`
	Name     string `json:"name"`
	Version  int64  `json:"version"`
	Path     string `json:"path,omitempty"`
	Children int    `json:"children,omitempty"`
}
type CategoryInput struct {
	Mutation
	Category
}
type Item struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Specification string `json:"specification"`
	Unit          string `json:"unit"`
	CategoryID    string `json:"category_id"`
	Price         string `json:"price"` // empty means unknown; "0" is a valid price
	Warning       string `json:"warning"`
	Version       int64  `json:"version"`
	CategoryName  string `json:"category_name,omitempty"`
}
type ItemInput struct {
	Mutation
	Item
}
type Asset struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	MIME string `json:"mime"`
	Kind string `json:"kind"`
}
type AssetInput struct {
	Mutation
	Name string `json:"name"`
	Kind string `json:"kind"`
	Data []byte `json:"data"`
}
type Signature struct {
	AssetID string `json:"asset_id"`
	Version int64  `json:"version"`
}
type SignatureInput struct {
	Mutation
	Signature
}
type ApplicationVersion struct {
	Version     int64  `json:"version"`
	Text        string `json:"text"`
	Submitted   string `json:"submitted"`
	Status      string `json:"status"`
	Reason      string `json:"reason"`
	ApproverID  string `json:"approver_id"`
	Approver    string `json:"approver"`
	Decided     string `json:"decided"`
	SignatureID string `json:"signature_id"`
}
type Application struct {
	ID      string `json:"id"`
	Number  string `json:"number"`
	OwnerID string `json:"owner_id"`
	Owner   string `json:"owner"`
	ApplicationVersion
}
type ApplicationInput struct {
	Mutation
	ID      string `json:"id"`
	Version int64  `json:"version"`
	Text    string `json:"text"`
}
type ApprovalInput struct {
	Mutation
	Version  int64  `json:"version"`
	Decision string `json:"decision"`
	Reason   string `json:"reason"`
}
type LineInput struct {
	ItemID           string `json:"item_id"`
	CategoryID       string `json:"category_id"`
	Quantity         string `json:"quantity"`
	Price            string `json:"price"` // only inbound accepts a price
	ItemVersion      int64  `json:"item_version"`
	BalanceVersion   int64  `json:"balance_version"`
	SourceLineID     string `json:"source_line_id"`
	TargetCategoryID string `json:"target_category_id"`
}
type DocumentInput struct {
	Mutation
	ApplicationID      string      `json:"application_id"`
	ApplicationVersion int64       `json:"application_version"`
	SourceID           string      `json:"source_id"`
	SignatureVersion   int64       `json:"signature_version"`
	Purpose            string      `json:"purpose"`
	Recipient          string      `json:"recipient"`
	Notes              string      `json:"notes"`
	Lines              []LineInput `json:"lines"`
	AssetIDs           []string    `json:"asset_ids"`
}
type Line struct {
	ID               string `json:"id"`
	ItemID           string `json:"item_id"`
	CategoryID       string `json:"category_id"`
	Category         string `json:"category"`
	Name             string `json:"name"`
	Specification    string `json:"specification"`
	Unit             string `json:"unit"`
	Quantity         string `json:"quantity"`
	Price            string `json:"price"`
	Amount           string `json:"amount"`
	SourceLineID     string `json:"source_line_id"`
	TargetCategoryID string `json:"target_category_id"`
	TargetCategory   string `json:"target_category"`
	Returned         string `json:"returned"`
	Remaining        string `json:"remaining"`
}
type Document struct {
	ID                 string   `json:"id"`
	Number             string   `json:"number"`
	Kind               string   `json:"kind"`
	OwnerID            string   `json:"owner_id"`
	Owner              string   `json:"owner"`
	Created            string   `json:"created"`
	ApplicationID      string   `json:"application_id"`
	ApplicationVersion int64    `json:"application_version"`
	SourceID           string   `json:"source_id"`
	SignatureID        string   `json:"signature_id"`
	Purpose            string   `json:"purpose"`
	Recipient          string   `json:"recipient"`
	Notes              string   `json:"notes"`
	Lines              []Line   `json:"lines"`
	AssetIDs           []string `json:"asset_ids"`
	KnownAmount        string   `json:"known_amount"`
	MissingPrices      int      `json:"missing_prices"`
	Status             string   `json:"status"`
}
type Balance struct {
	Item
	StockCategoryID string `json:"stock_category_id"`
	StockCategory   string `json:"stock_category"`
	Quantity        string `json:"quantity"`
	TotalQuantity   string `json:"total_quantity"`
	Low             bool   `json:"low"`
	BalanceVersion  int64  `json:"balance_version"`
}
type Movement struct {
	ID         string `json:"id"`
	DocumentID string `json:"document_id"`
	Number     string `json:"number"`
	Kind       string `json:"kind"`
	LineID     string `json:"line_id"`
	ItemID     string `json:"item_id"`
	CategoryID string `json:"category_id"`
	Quantity   string `json:"quantity"` // signed
	Actor      string `json:"actor"`
	Created    string `json:"created"`
}
type Filter struct {
	Search, Status, ItemID, CategoryID, OwnerID, From, To string
	Offset, Limit                                         int
	ParentID                                              *string
}
type Page[T any] struct {
	Items []T `json:"items"`
	Total int `json:"total"`
}
type ApplicationDetail struct {
	Application Application          `json:"application"`
	Versions    []ApplicationVersion `json:"versions"`
	Inbound     Page[Document]       `json:"inbound"`
	Totals      []Line               `json:"totals"`
}
type DocumentDetail struct {
	Document           Document       `json:"document"`
	Returns            Page[Document] `json:"returns"`
	Movements          Page[Movement] `json:"movements"`
	CanReadApplication bool           `json:"can_read_application"`
}
