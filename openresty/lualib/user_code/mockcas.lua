
local form = [[
    <html><head><title>MockCAS</title></head><body><h1>Fill in the netid with with you want to authenticate!</h1><form method="GET"><div><div><label for="id">Netid:</label></div><div><input type="text" name="id"></div></div><div><div><label for="service">Service:</label></div><div><input type="text" name="service" value="foo"></div></div><div><button type="submit">Submit</button></div></form></body></html>
]]
local function cas_login_form()
    return ngx.say(form)
end

return {
    cas_login_form = cas_login_form,
}