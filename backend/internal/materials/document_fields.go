package materials

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"sort"
	"strings"
)

// Personnel is an attribution snapshot, never a signature or an approval.
type Personnel struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
}
type DocumentFields struct {
	Supplier         string    `json:"supplier"`
	InvoiceNumber    string    `json:"invoice_number"`
	ContractNumber   string    `json:"contract_number"`
	CertificateCount *int64    `json:"certificate_count,omitempty"`
	Freight          string    `json:"freight"`
	Purchaser        Personnel `json:"purchaser"`
	Supervisor       Personnel `json:"supervisor"`
	Storekeeper      Personnel `json:"storekeeper"`
	Project          string    `json:"project"`
	ProjectNumber    string    `json:"project_number"`
	Station          string    `json:"station"`
	Nature           string    `json:"nature"`
	RecipientPerson  Personnel `json:"recipient_person"`
	SupplyReviewer   Personnel `json:"supply_reviewer"`
}

// SetPersonnelDirectory is wired once by the composition root. The public
// identity port returns enabled account IDs and usernames only.
func (s *Service) SetPersonnelDirectory(directory func(authorization.Actor) (map[string]string, error)) {
	s.personnel = directory
}
func (s *Service) Personnel(ctx context.Context) ([]Personnel, error) {
	a, e := actor(ctx, "stock")
	if e != nil {
		return nil, e
	}
	if !a.Grants.MaterialsInbound && !a.Grants.MaterialsOutbound {
		return nil, authorization.ErrDenied
	}
	out := []Personnel{}
	if s.personnel == nil {
		return out, nil
	}
	users, e := s.personnel(a)
	if e != nil {
		return nil, e
	}
	for id, name := range users {
		out = append(out, Personnel{UserID: id, Name: name})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name == out[j].Name {
			return out[i].UserID < out[j].UserID
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}
func (d DocumentFields) search() string {
	return strings.Join([]string{d.Supplier, d.InvoiceNumber, d.ContractNumber, d.Project, d.ProjectNumber, d.Station, d.Nature, d.Purchaser.Name, d.Supervisor.Name, d.Storekeeper.Name, d.RecipientPerson.Name, d.SupplyReviewer.Name}, " ")
}
func (s *Service) documentFields(ctx context.Context, kind string, in DocumentFields) (DocumentFields, error) {
	if _, e := actor(ctx, kind); e != nil {
		return in, e
	}
	if kind != "inbound" && kind != "outbound" {
		if in != (DocumentFields{}) {
			return in, invalid("仅入出库单支持采购或领用信息")
		}
		return in, nil
	}
	if kind == "inbound" && (in.Project != "" || in.ProjectNumber != "" || in.Station != "" || in.Nature != "" || in.RecipientPerson != (Personnel{}) || in.SupplyReviewer != (Personnel{})) {
		return in, invalid("入库单不能填写出库信息")
	}
	if kind == "outbound" && (in.Supplier != "" || in.InvoiceNumber != "" || in.ContractNumber != "" || in.CertificateCount != nil || in.Freight != "" || in.Purchaser != (Personnel{})) {
		return in, invalid("出库单不能填写入库信息")
	}
	for _, v := range []*string{&in.Supplier, &in.InvoiceNumber, &in.ContractNumber, &in.Project, &in.ProjectNumber, &in.Station, &in.Nature} {
		*v = strings.TrimSpace(*v)
		if !textValid(*v, 200, false) {
			return in, invalid("单据信息（最多200字）")
		}
	}
	if in.CertificateCount != nil && (*in.CertificateCount < 0 || *in.CertificateCount > 999999999) {
		return in, invalid("质量证明书份数（0至999999999的整数）")
	}
	in.Freight = strings.TrimSpace(in.Freight)
	if in.Freight != "" {
		n, e := units(in.Freight, false)
		if e != nil {
			return in, e
		}
		in.Freight = quantity(n)
	}
	people := []*Personnel{&in.Purchaser, &in.Supervisor, &in.Storekeeper, &in.RecipientPerson, &in.SupplyReviewer}
	var directory map[string]string
	for _, p := range people {
		p.Name = strings.TrimSpace(p.Name)
		if p.UserID != "" {
			if directory == nil {
				users, e := s.Personnel(ctx)
				if e != nil {
					return in, e
				}
				directory = map[string]string{}
				for _, u := range users {
					directory[u.UserID] = u.Name
				}
			}
			name, ok := directory[p.UserID]
			if !ok {
				return in, invalid("所选人员账号不存在或已停用，请重新选择")
			}
			p.Name = name
		}
		if !textValid(p.Name, 200, false) {
			return in, invalid("人员姓名")
		}
	}
	return in, nil
}
