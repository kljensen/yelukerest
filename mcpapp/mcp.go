package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
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
	// exchanger turns a verified OAuth identity into an internal PostgREST
	// credential (issue #274). Nil when no authorization server is wired up.
	exchanger *tokenExchanger
	// escapeHatchWritesEnabled allows POST/PATCH/DELETE through
	// postgrest_request (issue #331). The zero value is the shipped posture:
	// the hatch reads only, and writes go through submit_submission_change.
	escapeHatchWritesEnabled bool
}

// Server identity (issue #371). The SDK draws the distinction we have to
// respect: Implementation.Name is "intended for programmatic or logical use"
// and Title is "intended for UI and end-user contexts". A student picking this
// connector out of a list reads the Title, so it names their course; clients
// key configuration off the Name, so it stays fixed across terms and must not
// be derived from the course title.
const (
	// defaultServerName is the machine identifier when MCP_SERVER_NAME is
	// unset. Deployments set MCP_SERVER_NAME (mgt656-mcp in production) and
	// then leave it alone.
	defaultServerName = "course-mcp"
	// defaultServerTitle is the display name when COURSE_TITLE is unset,
	// which is every deployment that has not been told which course it runs.
	defaultServerTitle = "Course data MCP"
	// serverTitleSuffix turns a course title ("MGT656") into a connector
	// title ("MGT656 MCP Server").
	serverTitleSuffix = " MCP Server"
)

// serverName is the stable programmatic identifier this server advertises.
func serverName() string {
	return envOrDefault("MCP_SERVER_NAME", defaultServerName)
}

// serverTitle is the human-readable name a client shows in its connector
// list. It comes from COURSE_TITLE, the same deployment configuration the web
// client and the authapp OpenAPI document are titled from (authapp/openapi.go).
func serverTitle() string {
	title := envOrDefault("COURSE_TITLE", "")
	if title == "" {
		return defaultServerTitle
	}
	return title + serverTitleSuffix
}

func newMCPServer(deps *toolDeps) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    serverName(),
		Title:   serverTitle(),
		Version: "0.1.0",
	}, &mcp.ServerOptions{Instructions: serverInstructions(deps.escapeHatchWritesEnabled)})
	server.AddReceivingMiddleware(auditMiddleware(deps.logger))
	registerReadTools(server, deps)
	registerWriteTools(server, deps)
	registerEscapeHatchTools(server, deps)
	return server
}

// addTool registers a typed tool with an open output schema (issue #383).
// Left to itself the SDK infers the schema from Out and closes every object
// with additionalProperties: false, so a client validating results against a
// tool list it cached from an earlier release rejects every call once a field
// is added. Handing the SDK the inferred schema with those closures removed
// keeps the advertised schema and the server-side validator agreeing that
// unknown properties are allowed; types and required fields are untouched.
func addTool[In, Out any](server *mcp.Server, tool *mcp.Tool, handler mcp.ToolHandlerFor[In, Out]) {
	schema, err := jsonschema.For[Out](nil)
	if err != nil {
		panic(fmt.Sprintf("addTool %q: output schema: %v", tool.Name, err))
	}
	openObjects(schema)
	tool.OutputSchema = schema
	mcp.AddTool(server, tool, handler)
}

// openObjects removes additionalProperties: false from every object in the
// schema, root and nested, so unknown properties validate.
func openObjects(s *jsonschema.Schema) {
	if s == nil {
		return
	}
	if ap := s.AdditionalProperties; ap != nil && ap.Not != nil && reflect.ValueOf(*ap.Not).IsZero() {
		s.AdditionalProperties = nil
	}
	openObjects(s.AdditionalProperties)
	openObjects(s.Items)
	for _, property := range s.Properties {
		openObjects(property)
	}
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
