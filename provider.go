// Package onepassword provides a Docker Secrets Engine provider backed by
// 1Password Connect.
package onepassword

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1Password/connect-sdk-go/connect"
	"github.com/1Password/connect-sdk-go/onepassword"
	"github.com/docker/secrets-engine/plugin"
)

const (
	Realm = "op"

	connectHostEnvironment          = "OP_CONNECT_HOST"
	connectTokenEnvironment         = "OP_CONNECT_TOKEN"
	connectTokenFileEnvironment     = "OP_CONNECT_TOKEN_FILE"
	credentialsDirectoryEnvironment = "CREDENTIALS_DIRECTORY"
	connectTokenCredential          = "op-connect-token"
)

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

// NewFromEnvironment creates a provider using OP_CONNECT_HOST. It reads the
// token from OP_CONNECT_TOKEN_FILE when set, otherwise from the systemd
// op-connect-token credential, and finally from OP_CONNECT_TOKEN for backward
// compatibility with foreground use.
func NewFromEnvironment() (*Provider, error) {
	host, token, err := connectConfigurationFromEnvironment()
	if err != nil {
		return nil, err
	}
	return New(connect.NewClient(host, token)), nil
}

func connectConfigurationFromEnvironment() (host, token string, err error) {
	host = strings.TrimSpace(os.Getenv(connectHostEnvironment))
	if host == "" {
		return "", "", fmt.Errorf("%s is not set", connectHostEnvironment)
	}

	token, err = connectTokenFromEnvironment()
	if err != nil {
		return "", "", err
	}
	return host, token, nil
}

func connectTokenFromEnvironment() (string, error) {
	if tokenFile, ok := os.LookupEnv(connectTokenFileEnvironment); ok {
		tokenFile = strings.TrimSpace(tokenFile)
		if tokenFile == "" {
			return "", fmt.Errorf("%s is empty", connectTokenFileEnvironment)
		}
		return readConnectToken(tokenFile)
	}

	if credentialsDirectory, ok := os.LookupEnv(credentialsDirectoryEnvironment); ok {
		credentialsDirectory = strings.TrimSpace(credentialsDirectory)
		if credentialsDirectory == "" {
			return "", fmt.Errorf("%s is empty", credentialsDirectoryEnvironment)
		}
		return readConnectToken(filepath.Join(credentialsDirectory, connectTokenCredential))
	}

	if token, ok := os.LookupEnv(connectTokenEnvironment); ok {
		token = strings.TrimSpace(token)
		if token == "" {
			return "", fmt.Errorf("%s is empty", connectTokenEnvironment)
		}
		return token, nil
	}

	return "", fmt.Errorf(
		"connect token is not configured; provide the %q systemd credential, %s, or %s",
		connectTokenCredential,
		connectTokenFileEnvironment,
		connectTokenEnvironment,
	)
}

func readConnectToken(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read Connect token file %q: %w", path, err)
	}
	token := strings.TrimSpace(string(contents))
	if token == "" {
		return "", fmt.Errorf("connect token file %q is empty", path)
	}
	return token, nil
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
