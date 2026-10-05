def addr: tostring | ascii_downcase | ltrimstr("0x") | sub("^0+"; "");
($clients | map(select((.address | addr) == ($window.address | addr) and .pid == $window.pid)) | first) as $w |
($monitors | map(select(.id == $w.monitor)) | first) as $m |
if $w == null or $m == null then
  {time: $now, error: "Window exited, changed identity or lost its output"}
else
  ($w.workspace.id != null and $m.activeWorkspace.id != null) as $has_workspace |
  {
    time: $now, output: $m.name,
    focused: (if $active.address == null then null else ($active.address | addr) == ($w.address | addr) end),
    workspace_visible: (if $has_workspace then
      ($w.workspace.id == $m.activeWorkspace.id or $w.workspace.id == $m.specialWorkspace.id) else null end),
    fullscreen: $w.fullscreen,
    tearingBlockedBy: $m.tearingBlockedBy,
    directScanoutBlockedBy: $m.directScanoutBlockedBy,
    solitaryBlockedBy: $m.solitaryBlockedBy,
    hardwareCursorsInUse: $m.hardwareCursorsInUse,
    vrr: $m.vrr,
    mode: ($m | {width, height, refreshRate, scale, transform, dpmsStatus}),
    tearing: (if $has_workspace and ($m | has("activelyTearing") and has("solitary")) then
      $m.activelyTearing == true and ($m.solitary | addr) == ($w.address | addr) else null end),
    scanout: (if $has_workspace and ($m | has("directScanoutTo")) then
      ($m.directScanoutTo | addr) == ($w.address | addr) else null end)
  } |
  if .workspace_visible == false then .tearing = false | .scanout = false else . end
end
