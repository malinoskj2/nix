#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: markdown-to-pdf INPUT.md [OUTPUT.pdf]" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
input=$1
[[ -f $input ]] || {
  echo "markdown-to-pdf: no such file: $input" >&2
  exit 1
}
output=${2:-${input%.*}.pdf}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

puppeteer_config="$workdir/puppeteer.json"
echo '{"args":["--no-sandbox"]}' >"$puppeteer_config"

# htmlLabels renders node text in <foreignObject>, which rsvg-convert (pandoc's SVG
# rasterizer for LaTeX) can't read, so labels vanish from the PDF. Force plain <text>.
mermaid_config="$workdir/mermaid-config.json"
echo '{"flowchart":{"htmlLabels":false},"htmlLabels":false}' >"$mermaid_config"

rendered="$workdir/rendered.md"
: >"$rendered"

diagram_count=0
in_mermaid=0
diagram_file=""

while IFS= read -r line || [[ -n $line ]]; do
  if [[ $in_mermaid -eq 1 ]]; then
    if [[ $line == '```' ]]; then
      in_mermaid=0
      svg="$workdir/diagram-$diagram_count.svg"
      mmdc --puppeteerConfigFile "$puppeteer_config" --configFile "$mermaid_config" -i "$diagram_file" -o "$svg" --backgroundColor transparent
      printf '![](%s)\n' "$svg" >>"$rendered"
    else
      printf '%s\n' "$line" >>"$diagram_file"
    fi
    continue
  fi

  if [[ $line == '```mermaid' ]]; then
    in_mermaid=1
    diagram_count=$((diagram_count + 1))
    diagram_file="$workdir/diagram-$diagram_count.mmd"
    : >"$diagram_file"
    continue
  fi

  printf '%s\n' "$line" >>"$rendered"
done <"$input"

pandoc "$rendered" \
  --resource-path="$workdir:$(dirname "$input")" \
  --from=markdown+smart \
  --template="$MARKDOWN_TO_PDF_TEMPLATE" \
  --pdf-engine=xelatex \
  --highlight-style=tango \
  --toc \
  --number-sections \
  -V colorlinks=true \
  -o "$output"

echo "$output"
