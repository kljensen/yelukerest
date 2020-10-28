-- Called like
-- ban(600, ngx.HTTP_CLOSE)
local function ban(ban_duration, response)
    local banned_ips = ngx.shared.banned_ips
    local remote_addr = ngx.var.remote_addr
    local succ, err = banned_ips:set(remote_addr, 1, ban_duration)
    ngx.log(ngx.NOTICE, "Banning " .. remote_addr)
    return ngx.exit(response)
end

return {
    ban = ban;
}
