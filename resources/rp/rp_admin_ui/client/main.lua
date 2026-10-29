-- rp.tpm: сервер спрашивает поставленную на карте метку, клиент отвечает её позицией.
-- Права и сам телепорт — на сервере (rp_admin).

RegisterNetEvent("rp_admin:askWaypoint", function()
    local waypoint, reason = Open77.map.getWaypoint()
    local position = type(waypoint) == "table" and waypoint.position or nil
    TriggerServerEvent("rp_admin:waypoint", position, reason and tostring(reason) or nil)
end)
