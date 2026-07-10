package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestValidateAuthappJWT(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	tests := []struct {
		name    string
		claims  map[string]any
		wantErr string
	}{
		{
			name: "valid app token",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "app:authapp",
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "valid app token with audience array",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      []string{"other", "yelukerest-postgrest"},
				"sub":      "app:authapp",
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "legacy token missing issuer",
			claims: map[string]any{
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Unix(),
			},
			wantErr: "missing iss",
		},
		{
			name: "wrong audience",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "other",
				"sub":      "app:authapp",
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
			wantErr: "aud",
		},
		{
			name: "expired token",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "app:authapp",
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Add(-2 * time.Hour).Unix(),
				"nbf":      now.Add(-2 * time.Hour).Unix(),
				"exp":      now.Add(-time.Hour).Unix(),
			},
			wantErr: "exp is not in the future",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateAuthappJWT(testJWT(t, tt.claims), "yelukerest", "yelukerest-postgrest", now)
			if tt.wantErr == "" && err != nil {
				t.Fatalf("validateAuthappJWT error = %v", err)
			}
			if tt.wantErr != "" {
				if err == nil {
					t.Fatal("expected error")
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %q, want substring %q", err.Error(), tt.wantErr)
				}
			}
		})
	}
}

func TestValidateAuthappJWTRejectsMalformedToken(t *testing.T) {
	err := validateAuthappJWT("not-a-jwt", "yelukerest", "yelukerest-postgrest", time.Now())
	if err == nil {
		t.Fatal("expected error")
	}
}

func testJWT(t *testing.T, claims map[string]any) string {
	t.Helper()

	header, err := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}

	return strings.Join([]string{
		base64.RawURLEncoding.EncodeToString(header),
		base64.RawURLEncoding.EncodeToString(payload),
		"signature",
	}, ".")
}
