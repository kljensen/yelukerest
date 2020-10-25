
local http = require "resty.http"
local cjson_safe = require "cjson.safe"
local authapp_jwt = os.getenv("AUTHAPP_JWT")
local postgrest_host = os.getenv("POSTGREST_HOST")
local postgrest_port = os.getenv("POSTGREST_PORT")
assert(type(postgrest_host) == "string" and string.len(postgrest_host) > 0, "Environment variable POSTGREST_HOST not set")
assert(type(postgrest_port) == "string" and string.len(postgrest_port) > 0, "Environment variable POSTGREST_PORT not set")

-- Fetches a row from the `user_jwts` api
-- for the netid. This should be the netid
-- of the logged in user!
local function fetch_user_jwt_info(netid)

    -- If there is no net id, forbidden
    if netid == nil or netid == "" then
        return nil, "netid is nill", ngx.HTTP_FORBIDDEN
    end

    -- Fetch the JWT from postgrest
    local httpc = http.new()
    local res, err = httpc:request_uri("http://" .. postgrest_host .. ":" .. postgrest_port, {
      path = "/user_jwts",
      headers = {
        ["Authorization"] = "Bearer " .. authapp_jwt,
        ['Accept'] = 'application/vnd.pgrst.object+json',
      },
      query = {
          netid = "eq." .. netid,
      },
      keepalive_timeout = 60000,
      keepalive_pool = 10
    })

    -- If there is an error, return an error
    if err ~= nil or not res then
        return nil, "error fetching jwt", ngx.HTTP_FORBIDDEN
    end

    -- Parse the JSON response
    local data, err = cjson_safe.decode(res.body)
    if data == nil or err ~= nil then
        return nil, "error fetching jwt", ngx.HTTP_FORBIDDEN
    end

    -- Print the JWT in the response
    local jwt = data["jwt"]
    if jwt == nil or type(jwt) ~= "string" or jwt == "" then
        -- If there is no JWT, the user is not authorized
        return nil, "error parsing jwt", ngx.HTTP_FORBIDDEN
    end

    -- The returned data is assured to have a "jwt" element.
    return data, nil, ngx.HTTP_OK
end

-- Fetches a JWT for a user from postgrest.
-- Returns the JWT, an error message, and
-- an ngx error code
local function fetch_user_jwt(netid)
    local user_jwt_info, err, code =  fetch_user_jwt_info(netid)
    local jwt = nil
    if user_jwt_info ~= nil then
        jwt = user_jwt_info["jwt"]
    end
    return jwt, err, code
end

local function get_jwt(netid)
    local jwt, err, status_code = fetch_user_jwt(netid)
    ngx.log(ngx.WARN, "Error fetching JWT: ", err)
    if err == nil then
        ngx.header['content-type'] = 'text/plain; charset=utf-8' 
        ngx.print(jwt)
    else
        ngx.exit(status_code)
    end
end

-- Writes response containing the `user_jwt` info for a particular netid,
-- e.g.
-- {"jwt":"eyJhbGciOiJIUzI9ff_6uhTJRODYLism9e_AvcWfyWYGX0","id":3,"email":"kyle.jensen@yale.edu","netid":"klj39","name":"Kyle Jensen","lastname":null,"organization":null,"known_as":"Kyle","nickname":"shiny-turd","role":"faculty","created_at":"2017-12-27T19:13:36+00:00","updated_at":"2020-05-20T18:25:10.677357+00:00","team_nickname":"bright-fog"}%
local function get_me(netid)
    local data, err, status_code = fetch_user_jwt_info(netid)
    ngx.log(ngx.WARN, "Error fetching JWT: ", err)

    -- Bail early if error
    if err ~= nil then
        ngx.exit(status_code)
    end

    local encoded_data, err = cjson_safe.encode(data)
    if encoded_data == nil or err ~= nil then
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    ngx.header['encoded_data-type'] = 'application/json; charset=utf-8' 
    ngx.print(encoded_data)
end

-- See if there is a valid session cookie for the current request.
-- If there is, grab the JWT for it.
local function jwt_for_session_cookie()
end

return {
    get_jwt = get_jwt;
    get_me = get_me;
    fetch_user_jwt = fetch_user_jwt;
    fetch_user_jwt_info = fetch_user_jwt_info;
    postgrest_host = postgrest_host;
    postgrest_port = postgrest_port;
}
