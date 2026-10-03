---@meta
-------------------------------------------------------------------------------
-- tyr — neon oxwm rice
-------------------------------------------------------------------------------
-- Lives in the repo (hosts/tyr/modules/home/rice/oxwm) and is symlinked to
-- ~/.config/oxwm, so edit it here and reload with Mod+Shift+R.
-- Keybindings match mjolnir's config; the additions are marked "tyr".

---@module 'oxwm'

-------------------------------------------------------------------------------
-- Variables
-------------------------------------------------------------------------------
local modkey = "Mod4"
local terminal = "alacritty"

local home = os.getenv("HOME")
local scripts = home .. "/.config/oxwm/scripts/"

-- Fleet neon palette (same pink/cyan as fastfetch and the terminal)
local colors = {
    bg     = "#0b0d17",
    bg_alt = "#1e2430",
    fg     = "#d8dee9",
    dim    = "#63637d",
    pink   = "#ff4fa3",
    cyan   = "#2de2e6",
    purple = "#a277ff",
    yellow = "#ebcb8b",
    green  = "#7fdbca",
}

-- Nerd Font icons, written as codepoints so they survive any editor.
local icon = {
    nixos    = "\u{f313}",
    robot    = "\u{f06a9}",
    cpu      = "\u{f0ee0}",
    memory   = "\u{f035b}",
    load     = "\u{f04c5}",
    disk     = "\u{f02ca}",
    clock    = "\u{f017}",
    calendar = "\u{f073}",
}

-- Workspaces: terminal, code, agents, git, web, files, monitor, chat, misc
local tags = {
    "\u{f120}", "\u{f121}", "\u{f06a9}", "\u{f126}", "\u{f0ac}",
    "\u{f07b}", "\u{f080}", "\u{f086}", "\u{f0c3}",
}

local bar_font = "JetBrainsMono Nerd Font:style=Bold:size=11"

-------------------------------------------------------------------------------
-- Status bar blocks
-------------------------------------------------------------------------------
local function sep()
    return oxwm.bar.block.static({
        text = "  ",
        interval = 999999999,
        color = colors.dim,
        underline = false,
    })
end

local btop = { command = terminal .. " --class btop -e btop", floating = true }

local blocks = {
    oxwm.bar.block.static({
        text = icon.nixos .. " tyr",
        interval = 999999999,
        color = colors.pink,
        underline = true,
    }),
    sep(),
    -- Running agent sessions (claude, codex, hermes)
    oxwm.bar.block.shell({
        format = icon.robot .. " {}",
        command = scripts .. "agents.sh",
        interval = 5,
        color = colors.cyan,
        underline = true,
    }),
    sep(),
    oxwm.bar.block.shell({
        format = icon.cpu .. " {}%",
        command = scripts .. "cpu-usage.sh",
        interval = 3,
        color = colors.purple,
        underline = true,
        click = btop,
    }),
    sep(),
    oxwm.bar.block.ram({
        format = icon.memory .. " {used}/{total} GB",
        interval = 5,
        color = colors.pink,
        underline = true,
        click = btop,
    }),
    sep(),
    oxwm.bar.block.shell({
        format = icon.load .. " {}",
        command = "cut -d' ' -f1 /proc/loadavg",
        interval = 5,
        color = colors.green,
        underline = true,
        click = btop,
    }),
    sep(),
    oxwm.bar.block.shell({
        format = icon.disk .. " {}",
        command = "sh -c \"df -h --output=avail / | tail -1 | tr -d ' '\"",
        interval = 60,
        color = colors.yellow,
        underline = true,
    }),
    sep(),
    oxwm.bar.block.datetime({
        format = icon.calendar .. " {}",
        date_format = "%a %d %b",
        interval = 60,
        color = colors.purple,
        underline = true,
    }),
    sep(),
    oxwm.bar.block.datetime({
        format = icon.clock .. " {} ",
        date_format = "%H:%M:%S",
        interval = 1,
        color = colors.cyan,
        underline = true,
    }),
}

-------------------------------------------------------------------------------
-- Basic settings
-------------------------------------------------------------------------------
oxwm.set_terminal(terminal)
oxwm.set_modkey(modkey)
oxwm.set_tags(tags)
oxwm.tag.set_back_and_forth(true)
oxwm.set_floating_position("center")

-------------------------------------------------------------------------------
-- Layouts
-------------------------------------------------------------------------------
oxwm.set_layout_symbol("tiling", "[]=")
oxwm.set_layout_symbol("normie", "><>")
oxwm.set_layout_symbol("tabbed", "[=]")
oxwm.set_layout_symbol("grid", "[#]")
oxwm.set_layout_symbol("monocle", "[M]")
oxwm.set_layout_symbol("dwindle", "[\\]")

-- The agents workspace tiles as a grid, so several sessions stay visible.
oxwm.set_tag_layout(3, "grid")

-------------------------------------------------------------------------------
-- Appearance
-------------------------------------------------------------------------------
oxwm.border.set_width(3)
oxwm.border.set_focused_color(colors.pink)
oxwm.border.set_unfocused_color("#2a2e45")

-- Gaps stay on even with one window, so the wallpaper always shows.
oxwm.gaps.set_smart(false)
oxwm.gaps.set_inner(12, 12)
oxwm.gaps.set_outer(16, 16)

-------------------------------------------------------------------------------
-- Window rules
-------------------------------------------------------------------------------
oxwm.rule.add({ class = "btop", floating = true })
oxwm.rule.add({ class = "matrix", floating = true })
oxwm.rule.add({ instance = "gimp", floating = true })

-------------------------------------------------------------------------------
-- Status bar
-------------------------------------------------------------------------------
oxwm.bar.set_font(bar_font)
oxwm.bar.set_position("top")
oxwm.bar.set_blocks(blocks)

-- Tag colours: foreground, background, underline
-- (the bar keeps one background; only text and underline change per state)
oxwm.bar.set_scheme_normal(colors.dim, colors.bg, colors.bg)
oxwm.bar.set_scheme_occupied(colors.cyan, colors.bg, colors.cyan)
oxwm.bar.set_scheme_selected(colors.pink, colors.bg, colors.pink)
oxwm.bar.set_scheme_urgent(colors.yellow, colors.bg, colors.yellow)

-------------------------------------------------------------------------------
-- Keybindings
-------------------------------------------------------------------------------
oxwm.key.bind({ modkey }, "Return", oxwm.spawn_terminal())
oxwm.key.bind({ modkey }, "Q", oxwm.client.kill())

-- tyr: rofi is the launcher; your dmenu build is one Shift away
oxwm.key.bind({ modkey }, "D", oxwm.spawn({ "rofi", "-show", "drun" }))
oxwm.key.bind({ modkey, "Shift" }, "D", oxwm.spawn({ "sh", "-c", "dmenu_run -l 10" }))
oxwm.key.bind({ modkey }, "W", oxwm.spawn({ "rofi", "-show", "window" }))

-- tyr: effects on/off (picom: glow, rounded corners, glass, animations)
oxwm.key.bind({ modkey, "Shift" }, "P", oxwm.spawn({ "sh", "-c", "pkill -x picom || picom -b" }))
-- tyr: effects with real frosted-glass blur. Heavy without a GPU (about three
-- cores while a terminal scrolls); Mod+Shift+P twice goes back to the light set.
oxwm.key.bind({ modkey, "Control" }, "P", oxwm.spawn({ "sh", "-c",
    "pkill -x picom; sleep 0.4; picom -b --backend glx --blur-method dual_kawase --blur-strength 5" }))
-- tyr: matrix rain in a floating terminal
oxwm.key.bind({ modkey, "Shift" }, "M",
    oxwm.spawn({ "sh", "-c", terminal .. " --class matrix -e cmatrix -b -C magenta" }))
-- tyr: hide/show the bar
oxwm.key.bind({ modkey }, "B", oxwm.toggle_bar())

-- Copy a screenshot region to the clipboard (shared with mjolnir over RDP)
oxwm.key.bind({ modkey }, "S",
    oxwm.spawn({ "sh", "-c", "maim -s | xclip -selection clipboard -t image/png" }))

-- Keybind overlay
oxwm.key.bind({ modkey, "Shift" }, "Slash", oxwm.show_keybinds())

-- Window state toggles
oxwm.key.bind({ modkey, "Shift" }, "F", oxwm.client.toggle_fullscreen())
oxwm.key.bind({ modkey, "Shift" }, "Space", oxwm.client.toggle_floating())

-- Layout management
oxwm.key.bind({ modkey }, "F", oxwm.layout.set("normie"))
oxwm.key.bind({ modkey }, "C", oxwm.layout.set("tiling"))
oxwm.key.bind({ modkey }, "G", oxwm.layout.set("grid"))
oxwm.key.bind({ modkey }, "M", oxwm.layout.set("monocle"))
oxwm.key.bind({ modkey }, "N", oxwm.layout.cycle())

-- Master area controls (tiling layout)
oxwm.key.bind({ modkey }, "H", oxwm.set_master_factor(-5))
oxwm.key.bind({ modkey }, "L", oxwm.set_master_factor(5))
oxwm.key.bind({ modkey }, "I", oxwm.inc_num_master(1))
oxwm.key.bind({ modkey }, "P", oxwm.inc_num_master(-1))

-- Gaps toggle
oxwm.key.bind({ modkey }, "A", oxwm.toggle_gaps())

-- Window manager controls
oxwm.key.bind({ modkey, "Shift" }, "Q", oxwm.quit())
oxwm.key.bind({ modkey, "Shift" }, "R", oxwm.restart())

-- Focus movement
oxwm.key.bind({ modkey }, "J", oxwm.client.focus_stack(1))
oxwm.key.bind({ modkey }, "K", oxwm.client.focus_stack(-1))

-- Window movement (swap position in stack)
oxwm.key.bind({ modkey, "Shift" }, "J", oxwm.client.move_stack(1))
oxwm.key.bind({ modkey, "Shift" }, "K", oxwm.client.move_stack(-1))

-- tyr: hop between workspaces that have windows
oxwm.key.bind({ modkey }, "Tab", oxwm.tag.view_next_nonempty())
oxwm.key.bind({ modkey, "Shift" }, "Tab", oxwm.tag.view_previous_nonempty())

-- Workspaces: view, move window to, view several at once, window on several
for i = 1, 9 do
    local key = tostring(i)
    oxwm.key.bind({ modkey }, key, oxwm.tag.view(i - 1))
    oxwm.key.bind({ modkey, "Shift" }, key, oxwm.tag.move_to(i - 1))
    oxwm.key.bind({ modkey, "Control" }, key, oxwm.tag.toggleview(i - 1))
    oxwm.key.bind({ modkey, "Control", "Shift" }, key, oxwm.tag.toggletag(i - 1))
end

-- Keychord: Mod+Space then T opens a terminal
oxwm.key.chord({
    { { modkey }, "Space" },
    { {},         "T" }
}, oxwm.spawn_terminal())

-------------------------------------------------------------------------------
-- Autostart
-------------------------------------------------------------------------------
oxwm.autostart("xsetroot -cursor_name left_ptr")
oxwm.autostart("feh --no-fehbg --bg-fill " .. home .. "/.local/share/wallpapers/tyr-neon.png")
oxwm.autostart("picom -b")
