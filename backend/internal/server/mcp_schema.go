package server

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"reflect"
	"strconv"
	"strings"
	"unicode/utf8"
)

// mcpSchema is the deliberately small JSON Schema subset used by our tool
// contracts. The very same schema is published to clients and enforced here.
// Domain validation remains in the existing application services.
type mcpSchema struct {
	Type                 string                `json:"type,omitempty"`
	Properties           map[string]*mcpSchema `json:"properties,omitempty"`
	Required             []string              `json:"required,omitempty"`
	AdditionalProperties *bool                 `json:"additionalProperties,omitempty"`
	Items                *mcpSchema            `json:"items,omitempty"`
	Enum                 []string              `json:"enum,omitempty"`
	OneOf                []*mcpSchema          `json:"oneOf,omitempty"`
	Minimum              *float64              `json:"minimum,omitempty"`
	Maximum              *float64              `json:"maximum,omitempty"`
	MinLength            int                   `json:"minLength,omitempty"`
	MaxLength            int                   `json:"maxLength,omitempty"`
	MinItems             int                   `json:"minItems,omitempty"`
	MaxItems             int                   `json:"maxItems,omitempty"`
	Description          string                `json:"description,omitempty"`
}

func mcpObject(properties map[string]*mcpSchema, required ...string) *mcpSchema {
	no := false
	return &mcpSchema{Type: "object", Properties: properties, Required: required, AdditionalProperties: &no}
}
func mcpString(max int) *mcpSchema        { return &mcpSchema{Type: "string", MaxLength: max} }
func mcpEnum(values ...string) *mcpSchema { return &mcpSchema{Type: "string", Enum: values} }
func mcpNumber() *mcpSchema               { return &mcpSchema{Type: "number"} }
func mcpInt(min, max float64) *mcpSchema {
	return &mcpSchema{Type: "integer", Minimum: &min, Maximum: &max}
}
func mcpArray(item *mcpSchema, min, max int) *mcpSchema {
	return &mcpSchema{Type: "array", Items: item, MinItems: min, MaxItems: max}
}
func mcpTyped(value any, required ...string) *mcpSchema {
	schema := mcpType(reflect.TypeOf(value))
	schema.Required = required
	return schema
}
func mcpType(t reflect.Type) *mcpSchema {
	if t.Kind() == reflect.Pointer {
		return &mcpSchema{OneOf: []*mcpSchema{mcpType(t.Elem()), {Type: "null"}}}
	}
	switch t.Kind() {
	case reflect.Struct:
		properties := map[string]*mcpSchema{}
		for i := 0; i < t.NumField(); i++ {
			f := t.Field(i)
			key := strings.Split(f.Tag.Get("json"), ",")[0]
			if key != "" && key != "-" {
				properties[key] = mcpType(f.Type)
			}
		}
		return mcpObject(properties)
	case reflect.String:
		return mcpString(4096)
	case reflect.Bool:
		return &mcpSchema{Type: "boolean"}
	case reflect.Int, reflect.Int64:
		return mcpInt(-9007199254740991, 9007199254740991)
	case reflect.Float64:
		return mcpNumber()
	case reflect.Slice:
		return mcpArray(mcpType(t.Elem()), 0, 20000)
	default:
		panic("unsupported MCP schema type: " + t.String())
	}
}
func (s *mcpSchema) validate(value any, path string) error {
	if len(s.OneOf) > 0 {
		matches := 0
		for _, variant := range s.OneOf {
			if variant.validate(value, path) == nil {
				matches++
			}
		}
		if matches != 1 {
			return fmt.Errorf("%s must match exactly one permitted type", path)
		}
		return nil
	}
	invalid := func() error { return fmt.Errorf("%s must be %s", path, s.Type) }
	switch s.Type {
	case "object":
		v, ok := value.(map[string]any)
		if !ok {
			return invalid()
		}
		for _, key := range s.Required {
			if _, ok := v[key]; !ok {
				return fmt.Errorf("%s.%s is required", path, key)
			}
		}
		for key, item := range v {
			sub, ok := s.Properties[key]
			if !ok {
				return fmt.Errorf("%s.%s is unknown", path, key)
			}
			if err := sub.validate(item, path+"."+key); err != nil {
				return err
			}
			// JSON Schema integers include 1.0 and 1e0. Canonicalize for Go DTO decoders.
			if sub.Type == "integer" {
				v[key] = json.Number(strconv.FormatInt(mcpInteger(item), 10))
			}
		}
	case "array":
		v, ok := value.([]any)
		if !ok {
			return invalid()
		}
		if len(v) < s.MinItems || s.MaxItems > 0 && len(v) > s.MaxItems {
			return fmt.Errorf("%s array length is outside limits", path)
		}
		for i, item := range v {
			if err := s.Items.validate(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	case "string":
		v, ok := value.(string)
		if !ok {
			return invalid()
		}
		n := utf8.RuneCountInString(v)
		if n < s.MinLength || s.MaxLength > 0 && n > s.MaxLength {
			return fmt.Errorf("%s string length is outside limits", path)
		}
		if len(s.Enum) > 0 {
			for _, allowed := range s.Enum {
				if v == allowed {
					return nil
				}
			}
			return fmt.Errorf("%s has an unsupported value", path)
		}
	case "integer", "number":
		n, ok := value.(json.Number)
		if !ok {
			return invalid()
		}
		v, err := n.Float64()
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			return fmt.Errorf("%s requires a finite number", path)
		}
		if s.Type == "integer" && math.Trunc(v) != v {
			return invalid()
		}
		if s.Minimum != nil && v < *s.Minimum || s.Maximum != nil && v > *s.Maximum {
			return fmt.Errorf("%s number is outside limits", path)
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return invalid()
		}
	case "null":
		if value != nil {
			return invalid()
		}
	default:
		return fmt.Errorf("invalid tool schema")
	}
	return nil
}

// Reject duplicates instead of accepting whichever security-sensitive field
// happened to occur last. The nesting cap also bounds parser recursion.
func mcpDecode(r io.Reader) (any, error) {
	d := json.NewDecoder(r)
	d.UseNumber()
	value, err := mcpValue(d, 0)
	if err != nil {
		return nil, err
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, fmt.Errorf("expected one JSON value")
	}
	return value, nil
}
func mcpValue(d *json.Decoder, depth int) (any, error) {
	if depth > 32 {
		return nil, fmt.Errorf("JSON nesting limit exceeded")
	}
	token, err := d.Token()
	if err != nil {
		return nil, err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return token, nil
	}
	switch delimiter {
	case '{':
		object := map[string]any{}
		for d.More() {
			key, err := d.Token()
			if err != nil {
				return nil, err
			}
			name, ok := key.(string)
			if !ok {
				return nil, fmt.Errorf("object key must be a string")
			}
			if _, exists := object[name]; exists {
				return nil, fmt.Errorf("duplicate JSON key %q", name)
			}
			value, err := mcpValue(d, depth+1)
			if err != nil {
				return nil, err
			}
			object[name] = value
		}
		_, err = d.Token()
		return object, err
	case '[':
		array := []any{}
		for d.More() {
			value, err := mcpValue(d, depth+1)
			if err != nil {
				return nil, err
			}
			array = append(array, value)
		}
		_, err = d.Token()
		return array, err
	default:
		return nil, fmt.Errorf("unexpected JSON delimiter")
	}
}
func mcpInteger(value any) int64 {
	if value == nil {
		return 0
	}
	n, _ := value.(json.Number).Float64()
	return int64(n)
}
func mcpQueryValue(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case json.Number:
		f, _ := v.Float64()
		return strconv.FormatFloat(f, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(v)
	default:
		return ""
	}
}
