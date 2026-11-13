package materials

import (
	"context"
	"errors"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

func (s *Service) SaveCategory(ctx context.Context, in CategoryInput) (Category, error) {
	return mutate(ctx, s, "catalog", "category", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Category, error) {
		c := in.Category
		c.Name = strings.TrimSpace(c.Name)
		if !textValid(c.Name, 100, true) {
			return c, invalid("分类名称")
		}
		if c.ID == "" {
			if c.Version != 0 {
				return c, ErrConflict
			}
			c.ID = id()
		} else {
			old, e := getCategory(tx, c.ID)
			if e != nil {
				return c, e
			}
			if old.Version != c.Version {
				return c, ErrConflict
			}
		}
		depth := 1
		for parent := c.ParentID; parent != ""; {
			if parent == c.ID || depth >= 10 {
				return c, errors.New("分类不能循环且最多10层")
			}
			p, e := getCategory(tx, parent)
			if e != nil {
				return c, e
			}
			parent = p.ParentID
			depth++
		}
		var descendants int
		e := tx.QueryRow(`WITH RECURSIVE children(id,depth) AS (SELECT id,0 FROM materials_categories WHERE id=? UNION ALL SELECT c.id,ch.depth+1 FROM materials_categories c JOIN children ch ON c.parent_id=ch.id WHERE ch.depth<10) SELECT COALESCE(MAX(depth),0) FROM children`, c.ID).Scan(&descendants)
		if e != nil {
			return c, e
		}
		if depth+descendants > 10 {
			return c, errors.New("移动后子分类超过10层")
		}
		var count int
		if e = tx.QueryRow("SELECT COUNT(*) FROM materials_categories WHERE parent_id=? AND name=? AND id<>?", c.ParentID, c.Name, c.ID).Scan(&count); e != nil {
			return c, e
		}
		if count > 0 {
			return c, errors.New("同一层级已有同名分类")
		}
		c.Version++
		c.Path = ""
		c.Children = 0
		_, e = tx.Exec("INSERT INTO materials_categories(id,parent_id,name,version,body) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent_id=excluded.parent_id,name=excluded.name,version=excluded.version,body=excluded.body", c.ID, c.ParentID, c.Name, c.Version, raw(c))
		return c, e
	})
}
func (s *Service) Categories(ctx context.Context, f Filter) (Page[Category], error) {
	if _, e := actor(ctx, "stock"); e != nil {
		return Page[Category]{}, e
	}
	where := "LOWER(name) LIKE ? ESCAPE '!'"
	args := []any{like(f.Search)}
	if f.ParentID != nil {
		where += " AND parent_id=?"
		args = append(args, *f.ParentID)
	}
	p, e := paged[Category](s.db, "materials_categories", where, "name,id", args, f)
	if e != nil {
		return p, e
	}
	for i := range p.Items {
		p.Items[i].Path, e = categoryPath(s.db, p.Items[i].ID)
		if e != nil {
			return p, e
		}
		if e = s.db.QueryRow("SELECT COUNT(*) FROM materials_categories WHERE parent_id=?", p.Items[i].ID).Scan(&p.Items[i].Children); e != nil {
			return p, e
		}
	}
	return p, nil
}
func categoryPath(q queryer, key string) (string, error) {
	if key == "" {
		return "", ErrMissing
	}
	names := []string{}
	for key != "" {
		if len(names) >= 10 {
			return "", invalid("分类层级")
		}
		c, e := getCategory(q, key)
		if e != nil {
			return "", e
		}
		names = append([]string{c.Name}, names...)
		key = c.ParentID
	}
	return strings.Join(names, " / "), nil
}
func (s *Service) SaveItem(ctx context.Context, in ItemInput) (Item, error) {
	return mutate(ctx, s, "catalog", "item", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Item, error) {
		v := in.Item
		v.CategoryName = ""
		v.Name = strings.TrimSpace(v.Name)
		v.Unit = strings.TrimSpace(v.Unit)
		if !textValid(v.Name, 200, true) || !textValid(v.Specification, 200, false) || !textValid(v.Unit, 30, true) {
			return v, invalid("物料名称、规格或单位")
		}
		if _, e := getCategory(tx, v.CategoryID); e != nil {
			return v, e
		}
		n, e := units(v.Warning, false)
		if e != nil {
			return v, e
		}
		v.Warning = quantity(n)
		if v.Price != "" {
			n, e = units(v.Price, false)
			if e != nil {
				return v, e
			}
			v.Price = quantity(n)
		}
		if v.ID == "" {
			if v.Version != 0 {
				return v, ErrConflict
			}
			v.ID = id()
		} else {
			old, e := getItem(tx, v.ID)
			if e != nil {
				return v, e
			}
			if old.Version != v.Version {
				return v, ErrConflict
			}
			if old.Unit != v.Unit || old.Specification != v.Specification {
				var count int
				if e = tx.QueryRow("SELECT COUNT(*) FROM materials_lines WHERE item_id=?", v.ID).Scan(&count); e != nil {
					return v, e
				}
				if count > 0 {
					return v, errors.New("已有业务记录的物料不能更改单位或规格，请新建物料")
				}
			}
		}
		v.Version++
		_, e = tx.Exec("INSERT INTO materials_items(id,category_id,version,search,body) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET category_id=excluded.category_id,version=excluded.version,search=excluded.search,body=excluded.body", v.ID, v.CategoryID, v.Version, strings.ToLower(v.Name+" "+v.Specification+" "+v.Unit), raw(v))
		return v, e
	})
}
func (s *Service) Items(ctx context.Context, f Filter) (Page[Item], error) {
	if _, e := actor(ctx, "stock"); e != nil {
		return Page[Item]{}, e
	}
	where := "LOWER(search) LIKE ? ESCAPE '!'"
	args := []any{like(f.Search)}
	if f.CategoryID != "" {
		where += " AND category_id=?"
		args = append(args, f.CategoryID)
	}
	p, e := paged[Item](s.db, "materials_items", where, "search,id", args, f)
	if e != nil {
		return p, e
	}
	for i := range p.Items {
		p.Items[i].CategoryName, e = categoryPath(s.db, p.Items[i].CategoryID)
		if e != nil {
			return p, e
		}
	}
	return p, nil
}
func (s *Service) Item(ctx context.Context, key string) (Item, error) {
	if _, e := actor(ctx, "stock"); e != nil {
		return Item{}, e
	}
	v, e := getItem(s.db, key)
	if e != nil {
		return v, e
	}
	v.CategoryName, e = categoryPath(s.db, v.CategoryID)
	return v, e
}

func (s *Service) Stock(ctx context.Context, f Filter) (Page[Balance], error) {
	if _, e := actor(ctx, "stock"); e != nil {
		return Page[Balance]{}, e
	}
	p := Page[Balance]{Items: []Balance{}}
	f, e := pagination(f)
	if e != nil {
		return p, e
	}
	// Include unstocked items at their default category. A default-category edit
	// changes only this empty view, never moves a populated balance.
	from := `materials_items i LEFT JOIN materials_balances b ON b.item_id=i.id JOIN materials_categories c ON c.id=COALESCE(b.category_id,i.category_id)`
	where := "i.search LIKE ? ESCAPE '!'"
	args := []any{like(f.Search)}
	if f.ItemID != "" {
		where += " AND i.id=?"
		args = append(args, f.ItemID)
	}
	if f.CategoryID != "" {
		where += " AND c.id=?"
		args = append(args, f.CategoryID)
	}
	if e = s.db.QueryRow("SELECT COUNT(*) FROM "+from+" WHERE "+where, args...).Scan(&p.Total); e != nil {
		return p, e
	}
	args = append(args, f.Limit, f.Offset)
	rows, e := s.db.Query(`SELECT i.body,c.id,c.name,COALESCE(b.quantity,0),COALESCE(b.version,0),COALESCE((SELECT SUM(quantity) FROM materials_balances totals WHERE totals.item_id=i.id),0) FROM `+from+" WHERE "+where+" ORDER BY i.search,i.id,c.name,c.id LIMIT ? OFFSET ?", args...)
	if e != nil {
		return p, e
	}
	defer rows.Close()
	for rows.Next() {
		var b Balance
		var body string
		var n, total int64
		if e = rows.Scan(&body, &b.StockCategoryID, &b.StockCategory, &n, &b.BalanceVersion, &total); e != nil {
			return p, e
		}
		if e = decodeBody(body, &b.Item); e != nil {
			return p, e
		}
		b.Quantity = quantity(n)
		b.TotalQuantity = quantity(total)
		warning, e := units(b.Warning, false)
		if e != nil {
			return p, e
		}
		b.Low = total <= warning
		p.Items = append(p.Items, b)
	}
	if e = rows.Err(); e != nil {
		return p, e
	}
	if e = rows.Close(); e != nil {
		return p, e
	}
	// Close the result cursor before resolving paths: SQLite deliberately uses
	// a single connection. Cache shared ancestors' resulting category paths.
	paths := map[string]string{}
	for i := range p.Items {
		key := p.Items[i].StockCategoryID
		path, ok := paths[key]
		if !ok {
			path, e = categoryPath(s.db, key)
			if e != nil {
				return p, e
			}
			paths[key] = path
		}
		p.Items[i].StockCategory = path
	}
	return p, nil
}
