package materials

import (
	"context"
	"errors"
	"fmt"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

type CategoryDeletionInput struct {
	Mutation
	Version int64 `json:"version"`
	Deleted bool  `json:"deleted"`
}
type CategoryDeletion struct {
	Category  Category `json:"category"`
	Children  int      `json:"children"`
	Items     int      `json:"items"`
	Balances  int      `json:"balances"`
	CanDelete bool     `json:"can_delete"`
}

// Historical paths remain resolvable. Only new business targets require an
// active category; deletion never changes document snapshots or ledger rows.
func activeCategory(q queryer, key string) (Category, error) {
	return readJSON[Category](q, "SELECT body FROM materials_categories WHERE id=? AND id NOT IN (SELECT id FROM materials_category_deletions)", key)
}
func activeCategoryPath(q queryer, key string) (string, error) {
	if _, e := activeCategory(q, key); e != nil {
		return "", e
	}
	return categoryPath(q, key)
}
func categoryWithin(column string) string {
	return column + ` IN (WITH RECURSIVE subtree(id) AS (SELECT id FROM materials_categories WHERE id=? UNION ALL SELECT c.id FROM materials_categories c JOIN subtree p ON c.parent_id=p.id) SELECT id FROM subtree)`
}
func categoryDeletion(q queryer, key string) (CategoryDeletion, error) {
	var out CategoryDeletion
	c, e := getCategory(q, key)
	if e != nil {
		return out, e
	}
	c.Path, e = categoryPath(q, key)
	if e != nil {
		return out, e
	}
	var deleted int
	if e = q.QueryRow("SELECT COUNT(*) FROM materials_category_deletions WHERE id=?", key).Scan(&deleted); e != nil {
		return out, e
	}
	c.Deleted = deleted != 0
	out.Category = c
	for _, check := range []struct {
		sql    string
		target *int
	}{
		{"SELECT COUNT(*) FROM materials_categories WHERE parent_id=? AND id NOT IN (SELECT id FROM materials_category_deletions)", &out.Children},
		{"SELECT COUNT(*) FROM materials_items WHERE category_id=?", &out.Items},
		{"SELECT COUNT(*) FROM materials_balances WHERE category_id=? AND quantity<>0", &out.Balances},
	} {
		if e = q.QueryRow(check.sql, key).Scan(check.target); e != nil {
			return out, e
		}
	}
	out.CanDelete = !c.Deleted && out.Children == 0 && out.Items == 0 && out.Balances == 0
	return out, nil
}
func (s *Service) CategoryDeletion(ctx context.Context, key string) (CategoryDeletion, error) {
	if _, e := actor(ctx, "catalog"); e != nil {
		return CategoryDeletion{}, e
	}
	tx, a, e := s.chainRead(ctx)
	if e != nil {
		return CategoryDeletion{}, e
	}
	defer tx.Rollback()
	out, e := categoryDeletion(tx, key)
	if !a.Active() {
		return CategoryDeletion{}, authorization.ErrDenied
	}
	return out, e
}
func (s *Service) SetCategoryDeleted(ctx context.Context, key string, in CategoryDeletionInput) (Category, error) {
	return mutate(ctx, s, "catalog", "category/deletion/"+key, in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Category, error) {
		state, e := categoryDeletion(tx, key)
		if e != nil {
			return Category{}, e
		}
		c := state.Category
		if c.Version != in.Version {
			return c, ErrConflict
		}
		if c.Deleted == in.Deleted {
			return c, nil
		}
		if in.Deleted {
			if !state.CanDelete {
				return c, fmt.Errorf("不能删除：有效子分类%d个，在用物料档案%d个，非零库存%d项；请先处理相关资料和库存", state.Children, state.Items, state.Balances)
			}
			_, e = tx.Exec("INSERT INTO materials_category_deletions(id,deleted_at) VALUES(?,?)", key, now())
		} else {
			if c.ParentID != "" {
				if _, e = activeCategory(tx, c.ParentID); e != nil {
					return c, errors.New("请先恢复父分类")
				}
			}
			var count int
			if e = tx.QueryRow("SELECT COUNT(*) FROM materials_categories WHERE parent_id=? AND name=? AND id<>? AND id NOT IN (SELECT id FROM materials_category_deletions)", c.ParentID, c.Name, c.ID).Scan(&count); e != nil {
				return c, e
			}
			if count > 0 {
				return c, errors.New("该层级已有同名分类，请先重命名在用分类再恢复")
			}
			_, e = tx.Exec("DELETE FROM materials_category_deletions WHERE id=?", key)
		}
		if e != nil {
			return c, e
		}
		c.Version++
		c.Deleted = in.Deleted
		stored := c
		stored.Path = ""
		stored.Children = 0
		stored.Deleted = false
		_, e = tx.Exec("UPDATE materials_categories SET version=?,body=? WHERE id=?", c.Version, raw(stored), key)
		return c, e
	})
}
