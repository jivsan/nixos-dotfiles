------------------
---- MONITORS ----
------------------
-- The Dell is the main screen (120 Hz, on the right), the BenQ the second one on the
-- left, as in oxwm (modules/system/desktop.nix). Both are matched by their description,
-- not their connector: the RTX 5070 Ti (2026-10-19) renamed the Dell's port from DP-1
-- to DP-3 and listed the BenQ first, which gave the BenQ workspace 1 and the focus.
-- `hyprctl monitors` prints the descriptions.
local MAIN = "Dell Inc. Dell S2716DG #ASPWhPwBLKbd"   -- 2560x1440
local SIDE = "BNQ BenQ GW2470 L4G00969019"            -- 1920x1080

hl.monitor({ output = "desc:" .. SIDE, mode = "preferred", position = "0x0", scale = "1" })
hl.monitor({ output = "desc:" .. MAIN, mode = "2560x1440@120", position = "1920x0", scale = "1" })

-- Workspace 1 starts on the main screen, 2 on the second one.
hl.workspace_rule({ workspace = "1", monitor = "desc:" .. MAIN, default = true })
hl.workspace_rule({ workspace = "2", monitor = "desc:" .. SIDE, default = true })

-- Connector name of a screen (DP-3, HDMI-A-1, ...) by its description; nil before
-- the screens are up, e.g. while the config first loads at login.
local function output_of(desc)
    local ok, mons = pcall(hl.get_monitors)
    for _, m in ipairs(ok and mons or {}) do
        if m.description == desc then return m.name end
    end
end

-- The cursor starts on the main screen (this option takes a connector name).
local main_output = output_of(MAIN)
if main_output then hl.config({ cursor = { default_monitor = main_output } }) end


---------------------
---- MY PROGRAMS ----
---------------------
-- See-through terminals like on tyr (0.86). The flag keeps it to this session:
-- oxwm still gets the 0.94 from modules/home/terminal.nix.
local terminal    = "alacritty -o window.opacity=0.86"
local fileManager = "thunar"
local menu        = "rofi -show run -theme /home/christina/.config/hypr/rofi.rasi"   -- every command on PATH, like dmenu_run in oxwm


-------------------------------
---- NVIDIA / WAYLAND ENV  ----
-------------------------------
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
hl.env("XCURSOR_SIZE", "24")
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")


-------------------
---- AUTOSTART ----
-------------------
-- One eclipse per screen (drawn by hypr/wallpaper.sh), each growing out of
-- its own centre: tyr's pink one on the main screen, the cyan twin on the left.
local walls = "/home/christina/.config/hypr/"
local grow  = " --transition-type grow --transition-pos 0.5,0.64 --transition-fps 60"

hl.on("hyprland.start", function()
    -- Start on the main screen: workspace 1 lives there (rule above).
    hl.dispatch(hl.dsp.focus({ workspace = 1 }))
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("hypridle")
    local main, side = output_of(MAIN) or "DP-3", output_of(SIDE) or "HDMI-A-1"
    hl.exec_cmd(
        "awww-daemon & sleep 1 && awww img -o " .. main .. " " .. walls .. "wall.png" .. grow ..
        "; awww img -o " .. side .. " " .. walls .. "wall-cyan.png" .. grow)
    -- X11 games and apps (XWayland) open on the screen marked primary; mark the main one.
    hl.exec_cmd("sleep 3; DISPLAY=${DISPLAY:-:0} xrandr --output " .. main .. " --primary")
    hl.exec_cmd(terminal .. " --class scratchpad", { workspace = "special:scratch", float = true, size = "60% 60%" })
    -- Two shells on yggdrasil, side by side on workspace 2 (the BenQ).
    -- "silent" keeps you on workspace 1 on the Dell.
    local ygg = terminal .. " --title yggdrasil -e ssh christina@10.0.20.21"
    hl.exec_cmd(ygg, { workspace = "2 silent" })
    hl.exec_cmd(ygg, { workspace = "2 silent" })
    -- no wayvnc here: this is a local GPU session, not the remote VM
end)


------------------------------------
---- LAYER BLUR (frosted glass!) ----
------------------------------------
-- ignore_alpha: only blur behind what is actually drawn. That keeps the bar's
-- pink underlight (fainter than 0.6) and the rounded corners of the launcher
-- and the notifications from getting a square frosted patch.
hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.6 })
hl.layer_rule({ match = { namespace = "rofi" }, blur = true, ignore_alpha = 0.5 })
hl.layer_rule({ match = { namespace = "notifications" }, blur = true, ignore_alpha = 0.5 })


-----------------------
---- LOOK AND FEEL ----
-----------------------
-- tyr's neon rice (hosts/tyr/modules/home/rice), on a real GPU: pink round the
-- window you work in, cyan round the rest, and real frosted glass behind it.
hl.config({
    general = {
        gaps_in          = 6,   -- 12 between two windows, as on tyr
        -- The first 14px under the bar belong to its pink underlight, so the
        -- top gap is smaller: windows still start 18px below the bar.
        gaps_out         = { top = 4, right = 16, bottom = 16, left = 16 },
        border_size      = 3,
        col              = {
            -- Pink, with a lighter glint in it that circles the border once
            -- when a window opens (the borderangle animation below).
            active_border   = {
                colors = { "rgba(ff4fa3ff)", "rgba(ff4fa3ff)", "rgba(ffc9e3ff)", "rgba(ff4fa3ff)", "rgba(ff4fa3ff)" },
                angle = 45,
            },
            inactive_border = "rgba(2a2e45ff)",
        },
        resize_on_border = true,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    -- On a real GPU you can use hardware cursors. If the cursor disappears or
    -- flickers (a known NVIDIA quirk), set no_hardware_cursors = true.
    cursor = { enable_hyprcursor = false, no_hardware_cursors = false },

    decoration = {
        rounding         = 14,
        rounding_power   = 2,
        -- The focused window is solid, the others step back a little.
        active_opacity   = 1.0,
        inactive_opacity = 0.95,
        dim_inactive     = true,
        dim_strength     = 0.08,
        -- Neon glow: a centred, coloured shadow. Pink for the focused window,
        -- a fainter cyan for the rest (0xAARRGGBB; two cyan glows meet in
        -- every gap, so that one has to stay low).
        shadow           = { enabled = true, range = 26, render_power = 3, color = 0xb3ff4fa3, color_inactive = 0x382de2e6 },
        -- Full eye-candy: the 4060 Ti eats this for breakfast.
        blur             = { enabled = true, size = 8, passes = 3, new_optimizations = true, ignore_opacity = true, xray = false, vibrancy = 0.18 },
    },

    animations = { enabled = true },
})

hl.curve("glassy", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1 } } })
hl.curve("smoothOut", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
hl.animation({ leaf = "global", enabled = true, speed = 7, bezier = "smoothOut" })
hl.animation({ leaf = "windows", enabled = true, speed = 6, bezier = "glassy" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 6, bezier = "glassy", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 5, bezier = "glassy", style = "popin 92%" })
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "smoothOut" })
-- The glint in the pink border goes round once, over two seconds, when a
-- window opens. "once", not "loop": a looping border keeps the GPU drawing
-- all the time, and that card is also Octane's.
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.animation({ leaf = "borderangle", enabled = true, speed = 20, bezier = "linear", style = "once" })
hl.animation({ leaf = "fade", enabled = true, speed = 8, bezier = "smoothOut" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "glassy", style = "slidefade 15%" })

hl.config({ dwindle = { preserve_split = true } })
hl.config({ misc = { force_default_wallpaper = -1, disable_hyprland_logo = true } })

hl.config({
    input = {
        kb_layout = "no",
        kb_variant = "",
        kb_options = "",
        repeat_rate = 35,
        repeat_delay = 200,
        follow_mouse = 1,
        sensitivity = 0,
        touchpad = { natural_scroll = false },
    },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })


---------------------
---- KEYBINDINGS ----
---------------------
local main_mod = "SUPER"
hl.bind(main_mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(main_mod .. " + Q", hl.dsp.window.close())
hl.bind(main_mod .. " + SHIFT + Q",
    hl.dsp.exec_cmd("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"))
hl.bind(main_mod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(main_mod .. " + F", hl.dsp.window.float({ action = "toggle" }))
hl.bind(main_mod .. " + D", hl.dsp.exec_cmd(menu))
hl.bind(main_mod .. " + P", hl.dsp.window.pseudo())
hl.bind(main_mod .. " + L", hl.dsp.exec_cmd("hyprlock"))
hl.bind(main_mod .. " + h", hl.dsp.focus({ direction = "left" }))
hl.bind(main_mod .. " + l", hl.dsp.focus({ direction = "right" }))
hl.bind(main_mod .. " + k", hl.dsp.focus({ direction = "up" }))
hl.bind(main_mod .. " + j", hl.dsp.focus({ direction = "down" }))
for i = 1, 10 do
    local key = i % 10
    hl.bind(main_mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(main_mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end
hl.bind(main_mod .. " + TAB", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(main_mod .. " + SHIFT + TAB", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(main_mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(main_mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.bind("Print", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | swappy -f -"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("grim - | wl-copy"))
hl.bind("SUPER + S", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | wl-copy"))
hl.bind(main_mod .. " + A", hl.dsp.workspace.toggle_special("scratch"))
hl.bind("ALT + Tab", hl.dsp.exec_cmd("rofi -show window -theme /home/christina/.config/hypr/rofi.rasi"))


--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------
hl.window_rule({ name = "suppress-maximize-events", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({
    name = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true
})
