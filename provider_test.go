package onepassword

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1Password/connect-sdk-go/onepassword"
	"github.com/docker/secrets-engine/plugin"
)

type fakeClient struct {
	item  *onepassword.Item
	err   error
	vault string
	query string
}

func (c *fakeClient) GetItem(query, vault string) (*onepassword.Item, error) {
	c.query, c.vault = query, vault
	return c.item, c.err
}

func TestConnectConfigurationUsesExplicitTokenFile(t *testing.T) {
	clearConnectEnvironment(t)
	t.Setenv(connectHostEnvironment, " https://connect.example.test ")
	t.Setenv(connectTokenEnvironment, "environment-token")

	credentialDirectory := t.TempDir()
	if err := os.WriteFile(filepath.Join(credentialDirectory, connectTokenCredential), []byte("systemd-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(credentialsDirectoryEnvironment, credentialDirectory)

	tokenFile := filepath.Join(t.TempDir(), "connect-token")
	if err := os.WriteFile(tokenFile, []byte(" file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(connectTokenFileEnvironment, tokenFile)

	host, token, err := connectConfigurationFromEnvironment()
	if err != nil {
		t.Fatalf("connectConfigurationFromEnvironment() error = %v", err)
	}
	if got, want := host, "https://connect.example.test"; got != want {
		t.Errorf("host = %q, want %q", got, want)
	}
	if got, want := token, "file-token"; got != want {
		t.Errorf("token = %q, want %q", got, want)
	}
}

func TestConnectConfigurationUsesSystemdCredentialByDefault(t *testing.T) {
	clearConnectEnvironment(t)
	t.Setenv(connectHostEnvironment, "https://connect.example.test")
	t.Setenv(connectTokenEnvironment, "environment-token")

	credentialDirectory := t.TempDir()
	if err := os.WriteFile(filepath.Join(credentialDirectory, connectTokenCredential), []byte("systemd-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(credentialsDirectoryEnvironment, credentialDirectory)

	_, token, err := connectConfigurationFromEnvironment()
	if err != nil {
		t.Fatalf("connectConfigurationFromEnvironment() error = %v", err)
	}
	if got, want := token, "systemd-token"; got != want {
		t.Errorf("token = %q, want %q", got, want)
	}
}

func TestConnectConfigurationFallsBackToTokenEnvironment(t *testing.T) {
	clearConnectEnvironment(t)
	t.Setenv(connectHostEnvironment, "https://connect.example.test")
	t.Setenv(connectTokenEnvironment, "environment-token")

	_, token, err := connectConfigurationFromEnvironment()
	if err != nil {
		t.Fatalf("connectConfigurationFromEnvironment() error = %v", err)
	}
	if got, want := token, "environment-token"; got != want {
		t.Errorf("token = %q, want %q", got, want)
	}
}

func TestConnectConfigurationRejectsMissingToken(t *testing.T) {
	clearConnectEnvironment(t)
	t.Setenv(connectHostEnvironment, "https://connect.example.test")

	_, _, err := connectConfigurationFromEnvironment()
	if err == nil || !strings.Contains(err.Error(), connectTokenCredential) {
		t.Fatalf("connectConfigurationFromEnvironment() error = %v, want missing token error", err)
	}
}

func TestConnectConfigurationRejectsEmptyTokenFile(t *testing.T) {
	clearConnectEnvironment(t)
	t.Setenv(connectHostEnvironment, "https://connect.example.test")

	tokenFile := filepath.Join(t.TempDir(), "connect-token")
	if err := os.WriteFile(tokenFile, []byte(" \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(connectTokenFileEnvironment, tokenFile)

	_, _, err := connectConfigurationFromEnvironment()
	if err == nil || !strings.Contains(err.Error(), "is empty") {
		t.Fatalf("connectConfigurationFromEnvironment() error = %v, want empty token file error", err)
	}
}

func clearConnectEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		connectHostEnvironment,
		connectTokenEnvironment,
		connectTokenFileEnvironment,
		credentialsDirectoryEnvironment,
	} {
		t.Setenv(name, "")
		if err := os.Unsetenv(name); err != nil {
			t.Fatalf("unset %s: %v", name, err)
		}
	}
}

func TestGetSecretsUsesExplicitField(t *testing.T) {
	updated := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)
	client := &fakeClient{item: &onepassword.Item{UpdatedAt: updated, Fields: []*onepassword.ItemField{
		{Label: "token", Value: "secret-value"},
	}}}
	p := New(client)

	secrets, err := p.GetSecrets(context.Background(), plugin.MustParsePattern("op/production/api/token"))
	if err != nil {
		t.Fatalf("GetSecrets() error = %v", err)
	}
	if got, want := client.vault, "production"; got != want {
		t.Errorf("vault = %q, want %q", got, want)
	}
	if got, want := client.query, "api"; got != want {
		t.Errorf("item = %q, want %q", got, want)
	}
	if got, want := string(secrets[0].Value), "secret-value"; got != want {
		t.Errorf("value = %q, want %q", got, want)
	}
	if got := secrets[0].CreatedAt; !got.Equal(updated) {
		t.Errorf("CreatedAt = %s, want %s", got, updated)
	}
}

func TestGetSecretsUsesPasswordFieldWhenFieldIsOmitted(t *testing.T) {
	p := New(&fakeClient{item: &onepassword.Item{Fields: []*onepassword.ItemField{
		{Label: "username", Value: "alice", Purpose: "USERNAME"},
		{Label: "password", Value: "top-secret", Purpose: "PASSWORD"},
	}}})

	secrets, err := p.GetSecrets(context.Background(), plugin.MustParsePattern("op/vault/login"))
	if err != nil {
		t.Fatalf("GetSecrets() error = %v", err)
	}
	if got, want := string(secrets[0].Value), "top-secret"; got != want {
		t.Errorf("value = %q, want %q", got, want)
	}
}

func TestGetSecretsRejectsAmbiguousItem(t *testing.T) {
	p := New(&fakeClient{item: &onepassword.Item{Fields: []*onepassword.ItemField{
		{Label: "first", Value: "one"},
		{Label: "second", Value: "two"},
	}}})

	_, err := p.GetSecrets(context.Background(), plugin.MustParsePattern("op/vault/item"))
	if err == nil || !strings.Contains(err.Error(), "multiple value fields") {
		t.Fatalf("GetSecrets() error = %v, want ambiguity error", err)
	}
}

func TestGetSecretsDoesNotExpandWildcard(t *testing.T) {
	p := New(&fakeClient{})
	_, err := p.GetSecrets(context.Background(), plugin.MustParsePattern("op/**"))
	if !errors.Is(err, plugin.ErrNotFound) {
		t.Fatalf("GetSecrets() error = %v, want ErrNotFound", err)
	}
}

func TestParseID(t *testing.T) {
	tests := []struct {
		id      string
		wantErr bool
	}{
		{id: "op/vault/item"},
		{id: "op/vault/item/field"},
		{id: "other/vault/item", wantErr: true},
		{id: "op/vault", wantErr: true},
		{id: "op//item", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.id, func(t *testing.T) {
			_, _, _, err := parseID(test.id)
			if (err != nil) != test.wantErr {
				t.Fatalf("parseID(%q) error = %v, wantErr %t", test.id, err, test.wantErr)
			}
		})
	}
}
