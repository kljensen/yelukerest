
local http = require "resty.http"
local cjson_safe = require "cjson.safe"
local authapp_jwt = os.getenv("AUTHAPP_JWT")
local postgrest_host = os.getenv("POSTGREST_HOST")
local postgrest_port = os.getenv("POSTGREST_PORT")

-- Fetches a JWT for a user from postgrest.
-- Returns the JWT, an error message, and
-- an ngx error code
local function fetch_jwt_for_user(netid)

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
    if jwt == nil then
        -- If there is no JWT, the user is not authorized
        return nil, "error parsing jwt", ngx.HTTP_FORBIDDEN
    end
    return jwt, nil, ngx.HTTP_OK
end

local function get_jwt(netid)
    local jwt, err, status_code = fetch_jwt_for_user(netid)
    ngx.log(ngx.WARN, "Error fetching JWT: ", err)
    if err == nil then
        ngx.print(jwt)
    else
        ngx.exit(status_code)
    end
end

return {
    get_jwt = get_jwt;
    fetch_jwt_for_user = fetch_jwt_for_user;
}
