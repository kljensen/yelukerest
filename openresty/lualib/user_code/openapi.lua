local authapp = require "authapp"
local cas = require "cas"
local http = require "resty.http"
local cjson_safe = require "cjson.safe"

-- Gets a JWT from a session cookie, if there
-- is a valid one.
local function get_jwt_from_session_cookie()
    local session, netid = cas.session_and_netid()

    -- There is no netid in the session, do nothing.
    if netid == nil then
       return session, netid, nil, "invalid or non-existant session"
    end

    local jwt, err, status_code = authapp.fetch_user_jwt(netid)
    if jwt == nil or err ~= nil or status_code ~= ngx.HTTP_OK then
       return session, netid, nil, "error fetching jwt"
    end
    return session, netid, jwt, nil
end

local function set_jwt_auth_from_session_cookie()
    local session, netid, jwt, err = get_jwt_from_session_cookie()

    -- If there's an error, do nothing and return
    if jwt == nil or err ~= nil then
        return false
    end
    ngx.req.set_header("Authorization", "Bearer " .. jwt)
    return true
end

local function not_empty(s)
    return s ~= nil and s ~= ''
end

local function all_trim(s)
    return s:match( "^'*(.-)'*$" )
end

local function print_openapi_spec(jwt)
    local httpc = http.new()
    local options = {
      path = "/",
      keepalive_timeout = 60000,
      keepalive_pool = 2
    }
    if jwt ~= nil then
        options.headers = {
        ["Authorization"] = "Bearer " .. jwt,
      }
    end

    local res, err = httpc:request_uri("http://" .. authapp.postgrest_host .. ":" .. authapp.postgrest_port, options)

    -- If there is an error, return an error
    if err ~= nil or not res then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        return
    end

    -- Parse the JSON response
    local data, err = cjson_safe.decode(res.body)
    if data == nil or err ~= nil then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        return
    end

    local api_data = cjson_safe.decode(res.body)
    local swagger_info_title = os.getenv('SWAGGER_INFO_TITLE')
    local swagger_info_description = os.getenv('SWAGGER_INFO_DESCRIPTION')
    if api_data.info then
        if not_empty(swagger_info_title) then
            api_data.info.title = all_trim(swagger_info_title, '\'')
        end
        if not_empty(swagger_info_description) then
            api_data.info.description = all_trim(swagger_info_description, '\'')
        end
    end

    -- TODO: fix the hard-coding of /rest/ here, which in truth could
    -- vary. This is the prefix for postgrest. It should be stored in
    -- an environment variable and then likely also an nginx variable.
    api_data.host = ngx.var.host
    api_data.basePath = "/rest/"
    api_data.schemes = {ngx.var.scheme}

    -- Add JWT auth option to swagger-ui. This will give the user
    -- the option to pasted in their JWT. Note they'll need to put
    -- "Bearer " before the JWT.
    -- See https://github.com/PostgREST/postgrest/issues/1082
    api_data.securityDefinitions = {
        jwt = {
           name = "Authorization",
           type = "apiKey",
        },
    }
    -- Have to do this because "in" is a reserved word
    api_data.securityDefinitions.jwt["in"] = "header"

    api_data.security = {{jwt=cjson_safe.empty_array}}
    api_data.responses = {
		UnauthorizedError = {
			description = "JWT authorization is missing, invalid, or insufficient"
		}
	}
    

    local output = cjson_safe.encode(api_data)
    ngx.print(output)
end

return {
    get_jwt_from_session_cookie = get_jwt_from_session_cookie;
    set_jwt_auth_from_session_cookie = set_jwt_auth_from_session_cookie;
    print_openapi_spec=print_openapi_spec;
}
