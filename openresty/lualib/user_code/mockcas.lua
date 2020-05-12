
local ticket_store = ngx.shared.mockcas_tickets
local ticket_ttl = 600

-- The HTML for the login form
local form = [[
    <html><head><title>MockCAS</title></head><body><h1>Fill in the netid with with you want to authenticate!</h1><form method="GET"><div><div><label for="id">Netid:</label></div><div><input type="text" name="id"></div></div><div><div><label for="service">Service:</label></div><div><input type="text" name="service" value="foo"></div></div><div><button type="submit">Submit</button></div></form></body></html>
]]

-- XML returned when a ticket is invalid
local function get_failure_xml(ticket)
    return [[<cas:serviceResponse xmlns:cas="https://www.yale.edu/tp/cas"><cas:authenticationFailure code="INVALID_TICKET">Ticket "]] .. ticket .. [[" not recognized</cas:authenticationFailure></cas:serviceResponse> ]]
end

-- Gets the XML to return when we have a valid ticket
-- in the serviceValidate route
local function get_success_xml(user_id)
     return [[<cas:serviceResponse xmlns:cas="https:/www.yale.edu/tp.cas"><cas:authenticationSuccess><cas:user>]] .. user_id .. [[</cas:user><cas:foo>bar</cas:foo></cas:authenticationSuccess></cas:serviceResponse> ]]
end

local function redirect_to_service(user_id, service)
    local ticket = "mock-ticket-" .. user_id
    local succ, err, _ = ticket_store:set(ticket, user_id, ticket_ttl)
    if succ ~= true then
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    local encoded_args =  ngx.encode_args({ticket = ticket})
    local redirect_url = service .. "?" .. encoded_args
    return ngx.redirect(redirect_url, ngx.HTTP_MOVED_TEMPORARILY)
end

local function login()

    -- See if we have `id` or `service` parameters
    -- in the request URI.
    local args, err = ngx.req.get_uri_args()
    user_id = args["id"]
    service = args["service"]

    -- Either show them a form or redirect.
    if user_id == nil or service == nil then
        -- Give the user a fake login page.
        return ngx.say(form)
    else
        -- We have a user id and a service,
        -- create a mock ticket and redirect
        -- the user back to the service.
        return redirect_to_service(user_id, service)
    end
end

local function service_validate()
    ngx.header.content_type = 'text/xml';

    -- See if we got a `ticket` request parameter
    local args, err = ngx.req.get_uri_args()
    local ticket = args["ticket"]
    if ticket == nil then
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Look up the ticket
    local user_id, _ = ticket_store:get(ticket)
    local content = ""
    if user_id == nil then
        content = get_failure_xml(ticket)
    else
        content = get_success_xml(user_id)
    end
    ngx.say(content)
end

return {
    login = login,
    service_validate = service_validate,
}