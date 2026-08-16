// Package onepassword provides a Docker Secrets Engine provider backed by
// 1Password Connect.
package onepassword

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/1Password/connect-sdk-go/connect"
	"github.com/1Password/connect-sdk-go/onepassword"
	"github.com/docker/secrets-engine/plugin"
)

const Realm = "op"

// Client is the subset of the Connect client used by this provider.
// It deliberately makes tests independent of a live Connect server.
type Client interface {
	GetItem(itemQuery, vaultQuery string) (*onepassword.Item, error)
}

// Provider resolves IDs in the form op/<vault>/<item>/<field>.
// The field component can be omitted only when the item has exactly one
// suitable value field, or it contains a password-purpose field.
type Provider struct {
	client Client
}

var _ plugin.SecretsProvider = (*Provider)(nil)

// New creates a provider using an existing Connect client.
func New(client Client) *Provider {
	return &Provider{client: client}
}

// NewFromEnvironment creates a provider using OP_CONNECT_HOST and
// OP_CONNECT_TOKEN, as defined by the 1Password Connect SDK.
func NewFromEnvironment() (*Provider, error) {
	client, err := connect.NewClientFromEnvironment()
	if err != nil {
		return nil, fmt.Errorf("create 1Password Connect client: %w", err)
	}
	return New(client), nil
}

// GetSecrets resolves exact 1Password secret IDs. Wildcard patterns return no
// values because expanding a wildcard would require enumerating every item in
// the accessible vaults, which is both surprising and unnecessarily exposes
// metadata to the secrets engine.
func (p *Provider) GetSecrets(ctx context.Context, pattern plugin.Pattern) ([]plugin.Envelope, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	id := pattern.String()
	if strings.ContainsAny(id, "*?") {
		return nil, fmt.Errorf("%w: wildcard ids are not supported", plugin.ErrNotFound)
	}

	vault, itemName, field, err := parseID(id)
	if err != nil {
		return nil, err
	}
	item, err := p.client.GetItem(itemName, vault)
	if err != nil {
		return nil, fmt.Errorf("get 1Password item %q in vault %q: %w", itemName, vault, err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	value, err := valueForField(item, field)
	if err != nil {
		return nil, fmt.Errorf("resolve %q: %w", id, err)
	}
	createdAt := item.UpdatedAt
	if createdAt.IsZero() {
		createdAt = item.CreatedAt
	}
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}

	secretID, err := plugin.ParseID(id)
	if err != nil {
		return nil, fmt.Errorf("parse secret ID %q: %w", id, err)
	}
	return []plugin.Envelope{{ID: secretID, Value: []byte(value), CreatedAt: createdAt}}, nil
}

func parseID(id string) (vault, item, field string, err error) {
	parts := strings.Split(id, "/")
	if len(parts) < 3 || len(parts) > 4 || parts[0] != Realm {
		return "", "", "", fmt.Errorf("invalid 1Password secret ID %q; use %s/<vault>/<item>[/<field>]", id, Realm)
	}
	for _, part := range parts[1:] {
		if part == "" {
			return "", "", "", fmt.Errorf("invalid 1Password secret ID %q; ID segments must not be empty", id)
		}
	}
	field = ""
	if len(parts) == 4 {
		field = parts[3]
	}
	return parts[1], parts[2], field, nil
}

func valueForField(item *onepassword.Item, selector string) (string, error) {
	if item == nil {
		return "", fmt.Errorf("1Password returned no item")
	}
	if selector != "" {
		value := item.GetValue(selector)
		if value == "" {
			return "", fmt.Errorf("field %q is missing or empty", selector)
		}
		return value, nil
	}

	for _, field := range item.Fields {
		if field != nil && field.Purpose == "PASSWORD" && field.Value != "" {
			return field.Value, nil
		}
	}
	var candidate string
	for _, field := range item.Fields {
		if field == nil || field.Value == "" {
			continue
		}
		if candidate != "" {
			return "", fmt.Errorf("item has multiple value fields; specify a field in the secret ID")
		}
		candidate = field.Value
	}
	if candidate == "" {
		return "", fmt.Errorf("item has no non-empty value fields")
	}
	return candidate, nil
}
