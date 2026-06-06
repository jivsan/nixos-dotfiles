------------------
---- MONITORS ----
------------------
hl.monitor({
    output   = "",
    mode     = "2560x1440@60",     -- your native res (needs the bumped virtio framebuffer)
    position = "auto",
    scale    = "1",
})


---------------------
---- MY PROGRAMS ----
---------------------
local terminal    = "alacritty"
local fileManager = "thunar"
local menu        = "rofi -show drun -theme /home/christina/.config/hypr/rofi.rasi"


-------------------
---- AUTOSTART ----
-------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")          -- notifications (frosted)
    hl.exec_cmd("hypridle")
    hl.exec_cmd("swaybg -i /home/christina/.config/hypr/wall.png -m fill")
    hl.exec_cmd("wayvnc 0.0.0.0 5900")
end)


-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------
hl.env("XCURSOR_SIZE", "24")
hl.env("XCURSOR_THEME", "Adwaita")


------------------------------------
---- LAYER BLUR (frosted glass!) ----
------------------------------------
-- This is what turns the translucent bar/launcher/notifications into real
-- frosted glass — Hyprland blurs whatever is *behind* these layer surfaces.
hl.layer_rule({ match = { namespace = "waybar" },        blur = true, ignore_alpha = 0.1 })
hl.layer_rule({ match = { namespace = "rofi" },          blur = true })
hl.layer_rule({ match = { namespace = "notifications" }, blur = true })


-----------------------
---- LOOK AND FEEL ----
-----------------------
hl.config({
    general = {
        gaps_in   = 6,
        gaps_out  = 16,
        border_size = 2,
        col = {
            -- soft pink->cyan gradient, low alpha for a glassy edge
            active_border   = { colors = { "rgba(2de2e6aa)", "rgba(ff4fa3aa)" }, angle = 45 },
            inactive_border = "rgba(2a2e3a88)",
        },
        resize_on_border = true,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    -- needed over VNC so the cursor renders into the framebuffer
    cursor = { enable_hyprcursor = false, no_hardware_cursors = true },

    decoration = {
        rounding       = 14,
        rounding_power = 2,

        -- frosted translucency: windows let the blur + wallpaper show through
        active_opacity   = 0.94,
        inactive_opacity = 0.82,
        dim_inactive     = true,
        dim_strength     = 0.12,

        shadow = {
            enabled        = true,
            range          = 24,
            render_power   = 3,
            color          = 0xaa000000,
            color_inactive = 0x55000000,
        },

        -- ===== THE EYE-CANDY DIAL =====
        -- This block is by far the heaviest thing on a software-rendered VM
        -- over VNC. If it feels laggy, drop passes -> 2 then 1, size -> 4,
        -- or set enabled = false. Everything else stays cheap.
        blur = {
            enabled           = true,
            size              = 8,
            passes            = 3,
            new_optimizations = true,
            ignore_opacity    = true,
            xray              = false,
            vibrancy          = 0.18,
        },
    },

    animations = { enabled = true },
})

-- Clean, glassy easing (no bounce) ----------------------------------------
hl.curve("glassy",    { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1 } } })
hl.curve("smoothOut", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })

hl.animation({ leaf = "global",     enabled = true, speed = 7,  bezier = "smoothOut" })
hl.animation({ leaf = "windows",    enabled = true, speed = 6,  bezier = "glassy" })
hl.animation({ leaf = "windowsIn",  enabled = true, speed = 6,  bezier = "glassy",    style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 5,  bezier = "glassy",    style = "popin 92%" })
hl.animation({ leaf = "border",     enabled = true, speed = 10, bezier = "smoothOut" })
hl.animation({ leaf = "fade",       enabled = true, speed = 8,  bezier = "smoothOut" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6,  bezier = "glassy",    style = "slidefade 15%" })

hl.config({ dwindle = { preserve_split = true } })
hl.config({ misc = { force_default_wallpaper = -1, disable_hyprland_logo = true } })

hl.config({
    input = {
        kb_layout    = "no",
        kb_variant   = "",
        kb_options   = "",
        repeat_rate  = 35,
        repeat_delay = 200,
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad     = { natural_scroll = false },
    },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })


---------------------
---- KEYBINDINGS ----  (unchanged from your current setup)
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


--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------
hl.window_rule({ name = "suppress-maximize-events", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})

-- Float + center common dialogs for a tidier glassy feel
hl.window_rule({ match = { class = "thunar" }, float = true })
