# Design

The `home` desktop (Hyprland, j2bar and the GTK file chooser) follows one
design language: macOS 27's layout and type, drawn in Catppuccin Mocha on
glass, with a few motifs of its own. This file is the reference for it. Change
it when the language changes, and check new work against it.

## Principles

- **Apple's geometry, our colors.** Layout, type sizes and spacing are measured
  from the matching macOS 27 surface at 1x (the Wi-Fi menu, the small Calendar
  widget in the Clear style, the Apple menu, About This Mac). Color comes from
  Catppuccin, never from Apple.
- **Glass shows through.** Surfaces are translucent and blurred; their own fill
  sets the tone, and the glass refracts almost nothing.
- **Color has roles.** A color means the same thing on every surface (see
  [Color](#color)). Don't pick a color for a single element.
- **Off-palette values need a reason** in a comment next to them (for example,
  the window shadow's gray, because Catppuccin's neutrals are tinted blue).

## Color

Catppuccin Mocha everywhere. `users/jesse/global/palette.nix` defines it, along
with the glass opacity levels:

| Level | Opacity | Use |
|---|---|---|
| `chrome` | 55% | Title bars and toolbars (crust) |
| `layer` | 60% | Content stacked on a window |
| `root` | 80% | A window's own background |
| `solid` | 90% | Text areas |

Shell components use the Catppuccin palette with these roles:

| Role | Color | Where |
|---|---|---|
| Accent | peach | Panel titles, the calendar month, today, the status dot, slider fill, the selected output circle, primary buttons (85% hovered) |
| On accent | crust | Text and glyphs on peach |
| Text | text | Values, names, dates |
| Secondary | subtext1 | Status lines, calendar weekday dates |
| Key | sky at 65% | Section headers ("Details", "Output"), the names beside values, calendar weekends |
| Tertiary | overlay1 | Empty states, muted dot, shortcuts, footers |
| Separator | text at 10–12% | 1px rules |
| Hover | text at 10% | Row highlights, which keep their ink |
| Button | text at 14% (22% hovered) | Secondary buttons, such as Cancel and More Info… |
| Icon circle | text at 14–16% | Unselected device and network circles |
| Field | crust at 35% | Text inputs |
| Error | red | Failures |

Bar icons are white at 70% (`#ffffffb3`).

The GTK file chooser, Dolphin, Firefox and Orca use **mauve** as their accent. That
is the one known split from the peach used by the shell; keep new shell
components on peach.

## Type

The San Francisco family only.

| Font | Use |
|---|---|
| SF Pro Text | Menu text: 13 px rows and buttons, 11 px detail rows, 10.25 px in the calendar |
| SF Pro Display | The bar (weight 600 for the clock and window title), large titles (About This Computer's, 22 px) |
| SF Pro Rounded, semibold | Striped status text (14.5 px) |
| SF Symbols | Glyphs from SF Pro's private use area, each sized to Apple's ink |

Menus share one style, taken from the macOS menu: the title is bold, section
headers are bold, keys are semibold or bold, and rows and values are regular.
Title case, not capitals. Panels use this style whatever surface they
imitate (the calendar's month is "September", bold, like "Network").

## Glass

- **Hyprland blur** is strong (3 passes, vibrancy 0.2), because the shell's glass
  relies on what shows through it.
- **hyprglass** applies macOS 27's Clear widget glass to j2bar layers:
  almost no refraction, a directional rim, and a gleam in the lambda colors
  across a floating panel's top rim once when it opens. Its corner radii must
  match the surface: 12 for the on-screen display and polkit prompt,
  20 for notification banners and 36 for the launcher container.
- **The bar** is 8% glass with a 30% white 1px outline and no shadow.
- **Notification banners** are 55% glass, with no outline or app name.
- **The file chooser** draws its own frame: radius 20, a crust `chrome` body
  with a 1px text-at-18% inset edge, and a two-layer drop shadow.

## Menus

Bar widgets open floating panels in the style of a macOS menu bar item,
centered under the widget; the snowflake's system menu opens with its left edge
under the button, like the Apple menu. Network, Sound and the system menu share
one anatomy, and new menus should follow it:

1. **Header.** The panel's name on the left, bold, in the accent. On the right,
   the widget's live value as striped text after a status dot, such as
   "● 1 Gb/s" or "● 62%". Clicking the value opens the matching settings. The
   system menu's header is "NixOS" with the uptime, which opens the system
   monitor, since its settings already have a row.
2. **Status line** (optional). A key and a value, such as "Ethernet: Wired
   connection 1".
3. **Sections.** A 1px separator, a bold header in the key color, then rows.
   The system menu's groups have no header, like the Apple menu's.
4. **Hem.** The last element: the hem 12 px below the last row and 6 px from
   the panel's edge. It replaces a "Settings…" row.

Rows are regular text; hovering one fills it with the hover color and leaves
its text, symbols and shortcuts as they are. An action that needs confirming
(Restart…, Shut Down…, Log Out…) turns its row into a 36 px prompt, like the
network menu's password row: the question on the left, then a Cancel button and
the action in the accent, both 26 px tall with radius 7.

Geometry comes from each menu's own macOS surface. Network and Sound take the
Wi-Fi menu's:

- Width 308, with 5 px panel padding (Apple's row-highlight inset). Text sits
  14 px from the panel's edge.
- Rows are 22 px; rows with an icon circle are 32 px, with a 26 px circle.

The system menu takes the Apple menu's: width 284, 24 px rows, text 17 px in
(42 px after a symbol, which centers 24 px in), separators 16 px in, and
shortcuts ending 18 px from the edge. Its header and hem sit where the network
menu's do. In both:

- Hover highlights have radius 7.
- A separator is a 1 px line 5.5 px from the rows on either side.
- Place rows from their centers to avoid accumulating layout rounding.
- A panel maps at its final size and grows in place when its content changes.

The calendar is a widget tile, not a menu, but takes the same type, colors and
hem (scaled to 7 px stops) and the same 5 px padding and hem spacing.

About This Computer, opened from the system menu, keeps About This Mac's layout
but is a panel, not a window: it has no traffic lights and closes like the
other panels. Its title is in the accent, its labels in the key color and its
values in text, and it ends with the hem, 12 px below the footer.

## Motifs

- **The hem.** The 14 Catppuccin accents as hard stops, rosewater to lavender,
  at 90%, 3 px tall. It started as the file chooser's selvedge (168 px, 12 px
  stops). Menus use it at the same size; the calendar uses 7 px stops.
- **The sunset cloud.** A cloud cut from 14 horizontal stripes, lavender at
  the top to rosewater at the bottom (the hem reversed). It sits in the file
  chooser's sidebar.
- **Striped text.** Status values filled with the sunset cloud's stripes, drawn
  within the shell's text rendering.
- **The status dot.** A 9 px ● before striped text: peach when active, overlay1
  when muted or off.
- **The lambda colors.** Peach, yellow, teal, lavender, mauve and pink, in that
  order. They are the snowflake's lambdas, the workspace pills (workspace *n*
  takes color *n*), and hyprglass's gleam.

## Motion

Hyprland springs, defined in `hyprland.lua`:

| Curve | Use |
|---|---|
| `pop` (slight overshoot) | Windows and layers opening |
| `snap` | Window moves |
| `sway` (no visible bounce) | Workspace switches, like a macOS Space switch |
| `glide` (critically damped) | Anything closing, which never bounces |
| `land` (just under critical, stopped on arrival) | The file chooser sheet opening and closing |

- The polkit prompt scales in with "popin 80%"; the launcher animates itself.
- Notification banners slide in and out across the screen edge.
- The file chooser grows its parent window into itself and back (hyprsheet),
  without resizing either window.
- hyprfocus shrinks a window to 99% on focus. An open file chooser dips the same
  way through hyprsheet, which scales its frame rather than resizing it.
- Shimmer and gleam effects play on hover or on open, never continuously.

## Bar and windows

- The bar is on DP-2 only, 32 px. Left to right: the workspace pills, the
  active window title in the center, then media, volume and network (10 px
  apart), a `✦` separator and the clock.
- The shell owns the snowflake control button and its system menu.
- Bar icons have no tooltips when their menu shows the same information.
- Windows have radius 10 and no border; hyprfocus's dip marks focus. Hyprbars
  is only a thin drag strip on Alacritty and mpv.
- Icons are Catppuccin Mocha Papirus, built two ways. The GTK file chooser
  uses Couture: blue folders, with one accent per place and a gray trash in
  its list and sidebar. Dolphin uses Papirus-Dark-Catppuccin: peach folders,
  with mimetype icons recolored to the palette by
  `users/jesse/dolphin/papirus-catppuccin.py`.
- The cursor is OpenZone White Slim at 24.

## New components

Before calling a new surface done, check that it:

- uses the color roles above, peach as the accent, with no new colors;
- uses SF Pro Text in the menu style;
- ends a menu with the hem and keeps settings behind the header's value;
- matches its hyprglass radius to its surface radius;
- has been checked in the running desktop at 1x, not only in a mockup.
