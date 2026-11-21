#!/bin/bash
# Downloads tree-sitter and the bundled grammars at pinned versions, checks each download's
# SHA-256, and keeps only what the build needs (parser and scanner sources, headers, highlight
# queries, licenses). Run by make; fetches only what's missing or changed since the last run.
#
# The files live in VENDOR_DIR (default ~/Library/Caches/Vie-vendor), outside the repo, which
# may sit in an iCloud Drive-synced folder; Vendor in the repo is a link to it (ignored by git).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="${VENDOR_DIR:-$HOME/Library/Caches/Vie-vendor}"

# name | archive URL | SHA-256 | paths to keep (relative to the archive's top folder)
SOURCES=(
  "tree-sitter|https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v0.27.2.tar.gz|356528363bf7fbad12a2cfeb5a2678c0118ef886a4d69ad9a379db5fdef0735f|lib/src lib/include LICENSE"
  "c|https://github.com/tree-sitter/tree-sitter-c/archive/refs/tags/v0.24.2.tar.gz|2eeb4db31f8fa0865e45488503d13403923bcb485a1bdb637abff8c42dd97364|src queries LICENSE"
  "cpp|https://github.com/tree-sitter/tree-sitter-cpp/archive/refs/tags/v0.23.4.tar.gz|7a2c55afe3028f4105f25762ea58cc16537d1f5a1dcd9cca90410b3cd5d46051|src queries LICENSE"
  "javascript|https://github.com/tree-sitter/tree-sitter-javascript/archive/refs/tags/v0.25.0.tar.gz|9712fc283d3dc01d996d20b6392143445d05867a7aad76fdd723824468428b86|src queries LICENSE"
  "typescript|https://github.com/tree-sitter/tree-sitter-typescript/archive/refs/tags/v0.23.2.tar.gz|2c4ce711ae8d1218a3b2f899189298159d672870b5b34dff5d937bed2f3e8983|typescript/src tsx/src common queries LICENSE"
  "python|https://github.com/tree-sitter/tree-sitter-python/archive/refs/tags/v0.25.0.tar.gz|4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c|src queries LICENSE"
  "rust|https://github.com/tree-sitter/tree-sitter-rust/archive/refs/tags/v0.24.2.tar.gz|061e90a539a55a6aa65dceb0ad6425c50ab1a6e3e6d4ba430e2795ed4550f10e|src queries LICENSE"
  "go|https://github.com/tree-sitter/tree-sitter-go/archive/refs/tags/v0.25.0.tar.gz|2dc241b97872c53195e01b86542b411a3c1a6201d9c946c78d5c60c063bba1ef|src queries LICENSE"
  "json|https://github.com/tree-sitter/tree-sitter-json/archive/refs/tags/v0.24.8.tar.gz|acf6e8362457e819ed8b613f2ad9a0e1b621a77556c296f3abea58f7880a9213|src queries LICENSE"
  "bash|https://github.com/tree-sitter/tree-sitter-bash/archive/refs/tags/v0.25.1.tar.gz|2e785a761225b6c433410ef9c7b63cfb0a4e83a35a19e0f2aec140b42c06b52d|src queries LICENSE"
  "html|https://github.com/tree-sitter/tree-sitter-html/archive/refs/tags/v0.23.2.tar.gz|21fa4f2d4dcb890ef12d09f4979a0007814f67f1c7294a9b17b0108a09e45ef7|src queries LICENSE"
  "css|https://github.com/tree-sitter/tree-sitter-css/archive/refs/tags/v0.25.0.tar.gz|03965344d8c0435dc54fb45b281578420bb7db8b99df4d34e7e74105a274cb79|src queries LICENSE"
  "swift|https://github.com/alex-pinkus/tree-sitter-swift/releases/download/0.7.3/tree-sitter-swift.tar.gz|c595b41459b0816f246ec27f60e08392ff453135e12ef47a1852ed37fe6705fe|src queries LICENSE"
  "yaml|https://github.com/tree-sitter-grammars/tree-sitter-yaml/archive/refs/tags/v0.7.2.tar.gz|aeaff5731bb8b66c7054c8aed33cd5edea5f4cd2ac71654f3f6c2ba2073d8fac|src queries LICENSE"
  "toml|https://github.com/tree-sitter-grammars/tree-sitter-toml/archive/refs/tags/v0.7.0.tar.gz|7d52a7d4884f307aabc872867c69084d94456d8afcdc63b0a73031a8b29036dc|src queries LICENSE"
  "markdown|https://github.com/tree-sitter-grammars/tree-sitter-markdown/archive/refs/tags/v0.5.4.tar.gz|481ce2c1cce7b1130bc8455c186052bd0fa461f1ff488666994c6a3da7fca2ac|tree-sitter-markdown/src tree-sitter-markdown/queries tree-sitter-markdown-inline/src tree-sitter-markdown-inline/queries common LICENSE"
  # The LaTeX repository leaves out its generated parser (44 MB); the npm release has it.
  "latex|https://registry.npmjs.org/@pfoerster/tree-sitter-latex/-/tree-sitter-latex-0.6.0.tgz|c6ea767e34816f04405dec1b7b686090fe8859f2cb7c9be85576b5c6756f5b13|src/parser.c src/scanner.c src/tree_sitter LICENSE"
  "bibtex|https://github.com/latex-lsp/tree-sitter-bibtex/archive/8d04ed27b3bc7929f14b7df9236797dab9f3fa66.tar.gz|be1d4ae3cdb7ee85bc4c153bd54905ba50480dafb310bae2129761f654bf2d50|src LICENSE"
)

# Single files, fetched after the archives (so they can add to a grammar's folder):
# path in the vendor folder | URL | SHA-256. Neovim's queries (nvim-treesitter, Apache 2.0)
# for the grammars that ship none of their own, and for Markdown, whose own leave out task
# boxes, tables, quotes and strikethrough; at a pinned commit.
nvim="https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/52773f0d13a0c11d0c3ef33c14ab6ecc1c17148b"
FILES=(
  "nvim-treesitter/queries/markdown/highlights.scm|$nvim/runtime/queries/markdown/highlights.scm|7b71d4994cf3968e16d033ac59d28bb034427dd41be6a057b7a2985e2dfbe5b8"
  "nvim-treesitter/queries/markdown_inline/highlights.scm|$nvim/runtime/queries/markdown_inline/highlights.scm|7db9147da61de7491ede9155e554dc033d6a1b86ecd1b21f6849c018be9ac875"
  "latex/queries/highlights.scm|$nvim/runtime/queries/latex/highlights.scm|6990c21fdee2e47eee931c9c3c482f0cadfae03ca6520f4b4ec9cc83441a7b9a"
  "latex/queries/injections.scm|$nvim/runtime/queries/latex/injections.scm|989523087b1ac9e722b76c0c31f4967210c9400dde84d63c5619db48f50a2e83"
  "bibtex/queries/highlights.scm|$nvim/runtime/queries/bibtex/highlights.scm|fe2ed5d96a446e790277e19c34c66618120424a98e13cafe3c1e39da29ccfdc3"
  "nvim-treesitter/LICENSE|$nvim/LICENSE|c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"
)

manifest="$(printf '%s\n' "${SOURCES[@]}" "${FILES[@]}" | shasum -a 256 | cut -d' ' -f1)"
link="$root/Vendor"
if [ -f "$vendor/.manifest" ] && [ "$(cat "$vendor/.manifest")" = "$manifest" ]; then
  [ -L "$link" ] || ln -sfn "$vendor" "$link"
  exit 0
fi

mkdir -p "$vendor"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unpinned=0
check() { # name, expected SHA-256 ("-": not pinned yet), file
  local actual
  actual="$(shasum -a 256 "$3" | cut -d' ' -f1)"
  if [ "$2" = "-" ]; then
    echo "  unpinned; SHA-256 $actual"
    unpinned=1
  elif [ "$2" != "$actual" ]; then
    echo "SHA-256 mismatch for $1: expected $2, got $actual" >&2
    exit 1
  fi
}

for entry in "${SOURCES[@]}"; do
  IFS='|' read -r name url sum paths <<< "$entry"
  # Each folder records the entry it came from; a pinned one that matches is up to date.
  stamp="$vendor/$name/.source"
  if [ "$sum" != "-" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$entry" ]; then continue; fi
  echo "fetching $name"
  curl -fsSL --retry 2 -o "$work/$name.tar.gz" "$url"
  check "$name" "$sum" "$work/$name.tar.gz"
  mkdir -p "$work/$name"
  tar -xzf "$work/$name.tar.gz" -C "$work/$name"
  # GitHub archives have one top folder; release archives may not.
  top="$work/$name"
  entries=("$top"/*)
  if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then top="${entries[0]}"; fi
  rm -rf "$vendor/$name"
  for p in $paths; do
    [ -e "$top/$p" ] || { echo "missing $p in $name" >&2; exit 1; }
    mkdir -p "$vendor/$name/$(dirname "$p")"
    cp -R "$top/$p" "$vendor/$name/$p"
  done
  find "$vendor/$name" \( -name grammar.json -o -name node-types.json \) -delete
  echo "$entry" > "$stamp"
done

for entry in "${FILES[@]}"; do
  IFS='|' read -r path url sum <<< "$entry"
  file="$vendor/$path"
  if [ "$sum" != "-" ] && [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ]; then continue; fi
  echo "fetching $path"
  curl -fsSL --retry 2 -o "$work/file" "$url"
  check "$path" "$sum" "$work/file"
  mkdir -p "$(dirname "$file")"
  mv "$work/file" "$file"
done

if [ "$unpinned" = 1 ]; then
  echo "some sources aren't pinned yet; add their SHA-256 sums to $0" >&2
fi
echo "$manifest" > "$vendor/.manifest"
ln -sfn "$vendor" "$link"
echo "grammar sources in $vendor"
