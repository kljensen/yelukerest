package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// postgrestClient is the internal HTTP client tools will use to reach
// PostgREST. Phase 0 (issue #265) ships no tools that call PostgREST; read
// tools arrive in issue #266 and will use this client with the caller's
// internal JWT.
type postgrestClient struct {
	baseURL    *url.URL
	httpClient *http.Client
}

func newPostgRESTClient(host string, port string) *postgrestClient {
	return &postgrestClient{
		baseURL: &url.URL{
			Scheme: "http",
			Host:   net.JoinHostPort(host, port),
		},
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
}

// toolDeps carries per-process dependencies into tool handlers. Per-request
// identity arrives separately via identityFromRequest.
type toolDeps struct {
	logger    *slog.Logger
	postgrest *postgrestClient
}

func newMCPServer(deps *toolDeps) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "yelukerest-mcp",
		Title:   "Yelukerest MCP Server",
		Version: "0.1.0",
	}, nil)
	server.AddReceivingMiddleware(auditMiddleware(deps.logger))
	mcp.AddTool(server, &mcp.Tool{
		Name:        "whoami",
		Description: "Return the verified identity (subject, user id, netid, role) of the caller.",
	}, deps.whoami)
	return server
}

// identityFromRequest extracts the verified caller identity that the bearer
// middleware attached to the HTTP request. The streamable transport forwards
// it to handlers as mcp.RequestExtra.TokenInfo.
func identityFromRequest(req mcp.Request) (*identity, error) {
	extra := req.GetExtra()
	if extra == nil || extra.TokenInfo == nil {
		return nil, errors.New("no verified identity on request")
	}
	return identityFromTokenInfo(extra.TokenInfo), nil
}

type whoamiOutput struct {
	Subject string `json:"sub" jsonschema:"the token subject, e.g. user:42"`
	UserID  string `json:"user_id" jsonschema:"the numeric user id as a string"`
	NetID   string `json:"netid,omitempty" jsonschema:"the caller's netid, if present in the token"`
	Role    string `json:"role" jsonschema:"the caller's role, e.g. student or faculty"`
}

func (d *toolDeps) whoami(_ context.Context, req *mcp.CallToolRequest, _ any) (*mcp.CallToolResult, whoamiOutput, error) {
	id, err := identityFromRequest(req)
	if err != nil {
		return nil, whoamiOutput{}, err
	}
	return nil, whoamiOutput{
		Subject: id.Subject,
		UserID:  id.UserID,
		NetID:   id.NetID,
		Role:    id.Role,
	}, nil
}

// auditMiddleware logs one structured line per incoming MCP message: subject,
// method, tool name (for tools/call), outcome, and duration. It never logs
// Authorization headers, token strings, tool arguments, or request bodies.
func auditMiddleware(logger *slog.Logger) mcp.Middleware {
	return func(next mcp.MethodHandler) mcp.MethodHandler {
		return func(ctx context.Context, method string, req mcp.Request) (mcp.Result, error) {
			start := time.Now()
			subject := ""
			if extra := req.GetExtra(); extra != nil && extra.TokenInfo != nil {
				subject = extra.TokenInfo.UserID
			}
			tool := ""
			if params, ok := req.GetParams().(*mcp.CallToolParamsRaw); ok {
				tool = params.Name
			}

			result, err := next(ctx, method, req)

			outcome := "ok"
			if err != nil {
				outcome = "error"
			} else if callResult, ok := result.(*mcp.CallToolResult); ok && callResult != nil && callResult.IsError {
				outcome = "tool_error"
			}
			logger.Info("mcp_request",
				"subject", subject,
				"method", method,
				"tool", tool,
				"outcome", outcome,
				"duration_ms", time.Since(start).Milliseconds(),
			)
			return result, err
		}
	}
}
