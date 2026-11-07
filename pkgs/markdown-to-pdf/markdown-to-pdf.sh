#!/usr/bin/env bash

die() {
  echo "$1" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || die "Usage: markdown-to-pdf INPUT.md [OUTPUT.pdf]"
input=$1
[[ -f $input ]] || die "markdown-to-pdf: no such file: $input"
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
touch "$rendered"

diagram_count=0
diagram=""

while IFS= read -r line || [[ -n $line ]]; do
  if [[ -z $diagram && $line == '```mermaid' ]]; then
    diagram_count=$((diagram_count + 1))
    diagram="$workdir/diagram-$diagram_count"
    touch "$diagram.mmd"
  elif [[ -z $diagram ]]; then
    printf '%s\n' "$line" >>"$rendered"
  elif [[ $line != '```' ]]; then
    printf '%s\n' "$line" >>"$diagram.mmd"
  else
    mmdc --puppeteerConfigFile "$puppeteer_config" --configFile "$mermaid_config" -i "$diagram.mmd" -o "$diagram.svg" --backgroundColor transparent
    printf '![](%s)\n' "$diagram.svg" >>"$rendered"
    diagram=""
  fi
done <"$input"

[[ -z $diagram ]] || die "markdown-to-pdf: unclosed Mermaid block in $input"

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
