
local form = [[
    <html><head><title>MockCAS</title></head><body><h1>Fill in the netid with with you want to authenticate!</h1><form method="GET"><div><div><label for="id">Netid:</label></div><div><input type="text" name="id"></div></div><div><div><label for="service">Service:</label></div><div><input type="text" name="service" value="foo"></div></div><div><button type="submit">Submit</button></div></form></body></html>
]]

local ticket_store = ngx.shared.mockcas_tickets
local ticket_ttl = 600

local function redirect_to_service(id_param, service_param)
    local ticket = "mock-ticket-" .. id_param
    local succ, err, _ = ticket_store:set(ticket, id_param, ticket_ttl)
    if succ ~= true then
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    local encoded_args =  ngx.encode_args({ticket = ticket})
    local redirect_url = service_param .. "?" .. encoded_args
    return ngx.redirect(redirect_url, ngx.HTTP_MOVED_TEMPORARILY)
end

local function cas_login_form()

    -- See if we have `id` or `service` parameters
    -- in the request URI.
    local args, err = ngx.req.get_uri_args()
    id_param = args["id"]
    service_param = args["service"]

    -- Either show them a form or redirect.
    if id_param == nil or service_param == nil then
        -- Give the user a fake login page.
        return ngx.say(form)
    else
        -- We have a user id and a service,
        -- create a mock ticket and redirect
        -- the user back to the service.
        return redirect_to_service(id_param, service_param)
    end
end

return {
    cas_login_form = cas_login_form,
}