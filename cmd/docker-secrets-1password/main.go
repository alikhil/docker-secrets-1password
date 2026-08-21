package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	provider "github.com/alikhil/docker-secrets-1password"
	"github.com/docker/secrets-engine/plugin"
)

var version = "v0.2.0"

type logger struct{}

func (logger) Errorf(format string, args ...any) { slog.Error(fmt.Sprintf(format, args...)) }
func (logger) Printf(format string, args ...any) { slog.Info(fmt.Sprintf(format, args...)) }
func (logger) Warnf(format string, args ...any)  { slog.Warn(fmt.Sprintf(format, args...)) }

func main() {
	p, err := provider.NewFromEnvironment()
	if err != nil {
		slog.Error("configure 1Password provider", "error", err)
		os.Exit(1)
	}
	stub, err := plugin.NewSecretsProvider(p, plugin.Config{
		Version: plugin.MustNewVersion(version),
		Logger:  logger{},
		SecretsProviderConfig: &plugin.SecretsProviderConfig{
			Pattern: plugin.MustParsePattern(provider.Realm + "/**"),
		},
	})
	if err != nil {
		slog.Error("create Docker Secrets Engine plugin", "error", err)
		os.Exit(1)
	}
	if err := stub.Run(context.Background()); err != nil {
		slog.Error("run Docker Secrets Engine plugin", "error", err)
		os.Exit(1)
	}
}
