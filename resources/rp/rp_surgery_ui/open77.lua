resource "rp_surgery_ui"
version "0.1.0"
auto_start true
reload_policy "reconnect"
dependency "open77_contextmenu"
permissions { "network.events" }
client_script "client/main.lua"
web_file "web/index.html"
