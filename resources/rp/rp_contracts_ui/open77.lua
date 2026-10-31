resource "rp_contracts_ui"
version "0.1.0"
auto_start true
reload_policy "reconnect"
dependency "open77_contextmenu"
permissions { "network.events", "local.events" }
client_script "client/main.lua"
web_file "web/index.html"
