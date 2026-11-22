#!/bin/zsh
# Release notes from the commit subjects since the last release: feat under Top Features, fix and
# perf under Changelog, and the rest left out, as they change nothing a user sees. Markdown for the
# GitHub release, or with --plain, the plain text that AltStore, SideStore and Feather show under
# What's New. Run by .github/workflows/release.yml, from the commit being released.
#
#   scripts/release-notes.sh [--plain] <version> [<previous-tag>]      from the repo's root
set -euo pipefail

plain=
if [[ ${1:-} == --plain ]]; then
  plain=1
  shift
fi
version=$1
previous=${2:-}
repo=${GITHUB_REPOSITORY:-Visxoz/Lily-ios}

bullet='- '
if [[ -n $plain ]]; then
  bullet='• '
fi
subjects=
if [[ -n $previous ]]; then
  subjects=$(git log --reverse --format=%s "$previous..HEAD")
fi

# Each subject as a sentence, with its type taken off and a full stop added.
section() {
  local lines
  lines=$(printf '%s\n' "$subjects" | grep -E "^($2): " \
    | sed -E -e 's/^[a-z]+: //' -e 's/([^.!?])$/\1./' -e "s/^/$bullet/" || true)
  if [[ -z $lines ]]; then
    return 0
  fi
  found=1
  if [[ -n $plain ]]; then
    printf '%s\n%s\n\n' "$1" "$lines"
  else
    printf '## %s\n\n%s\n\n' "$1" "$lines"
  fi
}

# Images are read from the release's own tag, so old notes keep the artwork they shipped with.
assets=https://raw.githubusercontent.com/$repo/v$version/docs
if [[ -z $plain ]]; then
  printf '<img src="%s/banner.svg" width="100%%" alt="Lily: a native YouTube Music client for iPhone">\n\n' "$assets"
fi

found=
if [[ -z $previous ]]; then
  printf 'The first release of Lily.\n\n'
else
  section 'Top Features' feat
  section Changelog 'fix|perf'
  if [[ -z $found ]]; then
    printf 'Changes behind the scenes, with nothing new to see.\n\n'
  fi
fi

# The stores' own pages need no install steps, nor links they won't open.
if [[ -n $plain ]]; then
  exit 0
fi

if [[ -n $previous ]]; then
  printf 'Full list of changes: https://github.com/%s/compare/%s...v%s\n\n' "$repo" "$previous" "$version"
fi

ios=$(grep -m 1 -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' Lily.xcodeproj/project.pbxproj | cut -d' ' -f3 | sed 's/\.0$//')
source_url=https://github.com/$repo/releases/latest/download/source.json
redirect=https://intradeus.github.io/http-protocol-redirector?r=
button() {
  printf '<a href="%s%s"><img src="%s/add-%s.svg" width="230" alt="Add to %s"></a>' "$redirect" "$3" "$assets" "$1" "$2"
}

printf '## Install\n\n**iPhone and iPhone Duo** (iOS %s or later): ' "$ios"
if [[ -n $previous ]]; then
  printf 'Already have Lily? Your store offers %s as an update, and your sign-in, library and downloads stay. ' "$version"
fi
cat <<EOF
New to Lily? Add its source to your store on your iPhone, then install Lily from it.

<p align="center">$(button altstore AltStore "altstore://source?url=$source_url")&nbsp;&nbsp;$(button sidestore SideStore "sidestore://source?url=$source_url")&nbsp;&nbsp;$(button feather Feather "feather://source/$source_url")</p>

If a button does nothing, paste \`$source_url\` in your store's **Sources** tab. Or download \`Lily.ipa\` below and open it with any of them.

Apps signed with a free Apple ID last seven days. AltStore and SideStore refresh them in the background, and **Refresh All** in the store does it by hand.

**Found a bug?** [Open an issue](https://github.com/$repo/issues/new).
EOF
