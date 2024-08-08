package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
)

type UserJWTInfo struct {
	JWT          string `json:"jwt"`
	ID           int    `json:"id"`
	Email        string `json:"email"`
	NetID        string `json:"netid"`
	Name         string `json:"name"`
	LastName     string `json:"lastname"`
	Organization string `json:"organization"`
	KnownAs      string `json:"known_as"`
	Nickname     string `json:"nickname"`
	Role         string `json:"role"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
	TeamNickname string `json:"team_nickname"`
}

// Struct to hold config
type FetchJWTConfig struct {
	PostgrestHost string
	PostgrestPort string
	AuthappJWT    string
}

func fetchUserJWTInfo(netID string, config FetchJWTConfig) (*UserJWTInfo, error, int) {
	if netID == "" {
		return nil, fmt.Errorf("netid is nil"), http.StatusForbidden
	}

	url := fmt.Sprintf("http://%s:%s/user_jwts?netid=eq.%s", config.PostgrestHost, config.PostgrestPort, netID)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("error creating request: %v", err), http.StatusInternalServerError
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthappJWT)
	req.Header.Set("Accept", "application/vnd.pgrst.object+json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("error fetching jwt: %v", err), http.StatusForbidden
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response: %v", err), http.StatusInternalServerError
	}

	var data UserJWTInfo
	err = json.Unmarshal(body, &data)
	if err != nil {
		return nil, fmt.Errorf("error parsing jwt: %v", err), http.StatusForbidden
	}

	if data.JWT == "" {
		return nil, fmt.Errorf("error parsing jwt"), http.StatusForbidden
	}

	return &data, nil, http.StatusOK
}

func fetchUserJWT(netID string, config FetchJWTConfig) (string, error, int) {
	userJWTInfo, err, code := fetchUserJWTInfo(netID, config)
	if err != nil {
		return "", err, code
	}
	return userJWTInfo.JWT, nil, code
}

func getJWTHandler(config FetchJWTConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Println("Triggered the getJWTHandler")
		netID := r.Context().Value("netid").(string)
		if netID == "" {
			http.Error(w, "netid is nil", http.StatusUnauthorized)
			return
		}
		jwt, err, statusCode := fetchUserJWT(netID, config)
		if err != nil {
			log.Printf("Error fetching JWT: %v", err)
			http.Error(w, err.Error(), statusCode)
			return
		}

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte(jwt))
	}
}

func getMeHandler(config FetchJWTConfig) http.HandlerFunc {
	log.Println("Triggered the getMeHandler")
	return func(w http.ResponseWriter, r *http.Request) {

		// The netid is passed in the context by the middleware.
		// If the netid is not present, return an error.
		netID := r.Context().Value("netid").(string)
		if netID == "" {
			http.Error(w, "netid is nil", http.StatusUnauthorized)
			return
		}

		// Fetch the user's JWT info from the database.
		//
		data, err, statusCode := fetchUserJWTInfo(netID, config)
		if err != nil {
			log.Printf("Error fetching JWT: %v", err)
			http.Error(w, err.Error(), statusCode)
			return
		}

		encodedData, err := json.Marshal(data)
		if err != nil {
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Write(encodedData)
	}
}
