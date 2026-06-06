------------------
---- MONITORS ----
------------------
-- Wayland connector names differ from Xorg (DP-0 -> often DP-1, HDMI-0 -> HDMI-A-1).
-- Auto-config for the first boot; then run `hyprctl monitors`, read the real
-- names, and switch to the explicit lines below to match your oxwm layout.
-- hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "1" })
hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = "0x0", scale = "1" })
hl.monitor({ output = "DP-1", mode = "preferred", position = "1920x0", scale = "1" })


---------------------
---- MY PROGRAMS ----
---------------------
local terminal    = "alacritty"
local fileManager = "thunar"
local menu        = "rofi -show drun -theme /home/christina/.config/hypr/rofi.rasi"


-------------------------------
---- NVIDIA / WAYLAND ENV  ----
-------------------------------
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
hl.env("XCURSOR_SIZE", "24")
hl.env("XCURSOR_THEME", "Adwaita")


-------------------
---- AUTOSTART ----
-------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("hypridle")
    hl.exec_cmd(
        "awww-daemon & sleep 1 && awww img /home/christina/.config/hypr/wall.png --transition-type grow --transition-pos 0.1,0.9 --transition-fps 60")
    hl.exec_cmd("alacritty --class scratchpad", { workspace = "special:scratch", float = true, size = "60% 60%" })
    -- no wayvnc here: this is a local GPU session, not the remote VM
end)


------------------------------------
---- LAYER BLUR (frosted glass!) ----
------------------------------------
hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.1 })
hl.layer_rule({ match = { namespace = "rofi" }, blur = true })
hl.layer_rule({ match = { namespace = "notifications" }, blur = true })


-----------------------
---- LOOK AND FEEL ----
-----------------------
hl.config({
    general = {
        gaps_in          = 6,
        gaps_out         = 16,
        border_size      = 2,
        col              = {
            active_border   = { colors = { "rgba(2de2e6aa)", "rgba(7aa2f7aa)" }, angle = 45 },
            inactive_border = "rgba(2a2e3a88)",
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
        active_opacity   = 0.96,
        inactive_opacity = 0.86,
        dim_inactive     = true,
        dim_strength     = 0.1,
        shadow           = { enabled = true, range = 24, render_power = 3, color = 0xaa000000, color_inactive = 0x55000000 },
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
