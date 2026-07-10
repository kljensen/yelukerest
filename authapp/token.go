package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

func validateAuthappJWT(token string, expectedIssuer string, expectedAudience string, now time.Time) error {
	claims, err := decodeJWTClaims(token)
	if err != nil {
		return err
	}

	if err := requireStringClaim(claims, "iss", expectedIssuer); err != nil {
		return err
	}
	if err := requireAudienceClaim(claims, expectedAudience); err != nil {
		return err
	}
	if err := requireStringClaim(claims, "role", "app"); err != nil {
		return err
	}
	if err := requireStringClaim(claims, "app_name", "authapp"); err != nil {
		return err
	}
	if err := requireStringClaim(claims, "sub", "app:authapp"); err != nil {
		return err
	}

	exp, err := numericDateClaim(claims, "exp")
	if err != nil {
		return err
	}
	if exp <= now.Unix() {
		return errors.New("AUTHAPP_JWT exp is not in the future")
	}

	if _, err := numericDateClaim(claims, "iat"); err != nil {
		return err
	}
	if _, err := numericDateClaim(claims, "nbf"); err != nil {
		return err
	}

	return nil
}

func decodeJWTClaims(token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("AUTHAPP_JWT must have three JWT segments")
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("AUTHAPP_JWT payload is not base64url: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	claims := make(map[string]any)
	if err := decoder.Decode(&claims); err != nil {
		return nil, fmt.Errorf("AUTHAPP_JWT payload is not JSON: %w", err)
	}
	return claims, nil
}

func requireStringClaim(claims map[string]any, key string, want string) error {
	got, ok := claims[key].(string)
	if !ok || got == "" {
		return fmt.Errorf("AUTHAPP_JWT missing %s claim", key)
	}
	if got != want {
		return fmt.Errorf("AUTHAPP_JWT %s claim must be %q", key, want)
	}
	return nil
}

func requireAudienceClaim(claims map[string]any, want string) error {
	audience, ok := claims["aud"]
	if !ok {
		return errors.New("AUTHAPP_JWT missing aud claim")
	}

	if got, ok := audience.(string); ok {
		if got == want {
			return nil
		}
		return fmt.Errorf("AUTHAPP_JWT aud claim must include %q", want)
	}

	if got, ok := audience.([]any); ok {
		for _, item := range got {
			if item == want {
				return nil
			}
		}
	}
	return fmt.Errorf("AUTHAPP_JWT aud claim must include %q", want)
}

func numericDateClaim(claims map[string]any, key string) (int64, error) {
	value, ok := claims[key]
	if !ok {
		return 0, fmt.Errorf("AUTHAPP_JWT missing %s claim", key)
	}

	number, ok := value.(json.Number)
	if !ok {
		return 0, fmt.Errorf("AUTHAPP_JWT %s claim must be numeric", key)
	}
	result, err := number.Int64()
	if err != nil {
		return 0, fmt.Errorf("AUTHAPP_JWT %s claim must be an integer: %w", key, err)
	}
	return result, nil
}
