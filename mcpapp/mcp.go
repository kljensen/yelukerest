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

// postgrestClient is the internal HTTP client the read tools (tools.go) use
// to reach PostgREST. Every request carries the caller's own forwarded
// credential so PostgreSQL row-level security applies to each read.
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
	// intent mints and verifies the single-use intent tokens the write tools
	// (issue #267) and the escape hatch (issue #268) require.
	intent *intentSigner
}

func newMCPServer(deps *toolDeps) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "yelukerest-mcp",
		Title:   "Yelukerest MCP Server",
		Version: "0.1.0",
	}, &mcp.ServerOptions{Instructions: serverInstructions})
	server.AddReceivingMiddleware(auditMiddleware(deps.logger))
	registerReadTools(server, deps)
	registerWriteTools(server, deps)
	registerEscapeHatchTools(server, deps)
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
