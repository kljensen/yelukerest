package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// validateAuthappJWT checks the AUTHAPP_JWT service credential authapp
// presents to PostgREST when minting user tokens.
func validateAuthappJWT(token string, expectedIssuer string, expectedAudience string, now time.Time) error {
	return validateServiceJWT(token, "AUTHAPP_JWT", "authapp", expectedIssuer, expectedAudience, now)
}

// validateServiceJWT applies the shared service-credential claim checks.
// The label names the environment variable in error messages so operators
// can tell which credential is bad; appName is the required app_name (and,
// with the "app:" prefix, the required subject).
func validateServiceJWT(token string, label string, appName string, expectedIssuer string, expectedAudience string, now time.Time) error {
	claims, err := decodeJWTClaims(token, label)
	if err != nil {
		return err
	}

	if err := requireStringClaim(claims, label, "iss", expectedIssuer); err != nil {
		return err
	}
	if err := requireAudienceClaim(claims, label, expectedAudience); err != nil {
		return err
	}
	if err := requireStringClaim(claims, label, "role", "app"); err != nil {
		return err
	}
	if err := requireStringClaim(claims, label, "app_name", appName); err != nil {
		return err
	}
	if err := requireStringClaim(claims, label, "sub", "app:"+appName); err != nil {
		return err
	}

	exp, err := numericDateClaim(claims, label, "exp")
	if err != nil {
		return err
	}
	if exp <= now.Unix() {
		return fmt.Errorf("%s exp is not in the future", label)
	}

	if _, err := numericDateClaim(claims, label, "iat"); err != nil {
		return err
	}
	if _, err := numericDateClaim(claims, label, "nbf"); err != nil {
		return err
	}

	return nil
}

func decodeJWTClaims(token string, label string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("%s must have three JWT segments", label)
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("%s payload is not base64url: %w", label, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	claims := make(map[string]any)
	if err := decoder.Decode(&claims); err != nil {
		return nil, fmt.Errorf("%s payload is not JSON: %w", label, err)
	}
	return claims, nil
}

func requireStringClaim(claims map[string]any, label string, key string, want string) error {
	got, ok := claims[key].(string)
	if !ok || got == "" {
		return fmt.Errorf("%s missing %s claim", label, key)
	}
	if got != want {
		return fmt.Errorf("%s %s claim must be %q", label, key, want)
	}
	return nil
}

func requireAudienceClaim(claims map[string]any, label string, want string) error {
	audience, ok := claims["aud"]
	if !ok {
		return fmt.Errorf("%s missing aud claim", label)
	}

	if got, ok := audience.(string); ok {
		if got == want {
			return nil
		}
		return fmt.Errorf("%s aud claim must include %q", label, want)
	}

	if got, ok := audience.([]any); ok {
		for _, item := range got {
			if item == want {
				return nil
			}
		}
	}
	return fmt.Errorf("%s aud claim must include %q", label, want)
}

func numericDateClaim(claims map[string]any, label string, key string) (int64, error) {
	value, ok := claims[key]
	if !ok {
		return 0, fmt.Errorf("%s missing %s claim", label, key)
	}

	number, ok := value.(json.Number)
	if !ok {
		return 0, fmt.Errorf("%s %s claim must be numeric", label, key)
	}
	result, err := number.Int64()
	if err != nil {
		return 0, fmt.Errorf("%s %s claim must be an integer: %w", label, key, err)
	}
	return result, nil
}
