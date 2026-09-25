#!/usr/bin/env bash

volume=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)

pw-dump | jq --compact-output --arg volume "$volume" '
  (
    [.[] | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default")
      | .metadata[]? | select(.key == "default.audio.sink") | .value.name]
    | first // ""
  ) as $default
  | (
    [.[] | select(.type == "PipeWire:Interface:Device") | {key: (.id | tostring), value: .info.props}]
    | from_entries
  ) as $devices
  | {
    volume: (($volume | capture("Volume: (?<v>[0-9.]+)") | .v | tonumber) // 0),
    muted: ($volume | test("MUTED")),
    outputs: [
      .[]
      | select(.type == "PipeWire:Interface:Node" and .info.props["media.class"] == "Audio/Sink")
      | .info.props as $node
      | ($devices[$node["device.id"] // "" | tostring] // {}) as $device
      | ([$node["node.name"], $node["node.description"], $device["device.description"]]
        | map(. // "" | ascii_downcase) | join(" ")) as $names
      | ($device["device.form-factor"] // $node["device.form-factor"] // "") as $form
      | {
        id: .id,
        name: ($node["node.description"] // $node["node.nick"] // $node["node.name"]),
        default: ($node["node.name"] == $default),
        kind: (
          if ($names | test("airpods")) then "airpods"
          elif ($names | test("hdmi|displayport")) then "display"
          elif ($form | test("headphone|headset|handsfree")) then "headphones"
          elif $form == "" and $device["device.bus"] == "bluetooth" then "headphones"
          else "speaker"
          end
        )
      }
    ]
  }
'
