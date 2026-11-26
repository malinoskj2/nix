vulkaninfo --summary 2>/dev/null |
  grep -E 'deviceType += PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED|VIRTUAL)_GPU' >/dev/null
