#!/usr/bin/env bash
# Resolve the version a template publish should use from the ref, and stamp it into
# every src/*/devcontainer-template.json.
#
#   REF_TYPE=tag    REF_NAME=v0.1.0 SHA=<sha> .github/scripts/stamp-templates.sh
#   REF_TYPE=branch REF_NAME=main   SHA=<sha> .github/scripts/stamp-templates.sh
#
# Prints `version=` and `image_tag=` on stdout in $GITHUB_OUTPUT format; progress goes
# to stderr.
#
# Shared by publish.yaml (the real publish) and test.yaml (a dry run against a throwaway
# registry) so the two cannot drift. The publish only ever runs after a merge, so its
# logic has to be exercisable in the pull request that changes it.
set -euo pipefail

REF_TYPE="${REF_TYPE:?REF_TYPE is required (tag|branch)}"
SHA="${SHA:?SHA is required}"

if [ "$REF_TYPE" = tag ]; then
    REF_NAME="${REF_NAME:?REF_NAME is required for a tag}"
    # OCI tags conventionally carry no leading v, and the images' semver tags
    # (docker/metadata-action's {{version}}) already strip it -- so strip it here too, or
    # a released template and the image it points at would disagree.
    version="${REF_NAME#v}"
    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "tag '${REF_NAME}' is not vX.Y.Z, so it cannot be a template version" >&2
           exit 1 ;;
    esac
    image_tag="$version"
else
    # Not a release. A prerelease version keeps `latest` tracking main while the exact
    # tag stays traceable to the commit, mirroring the images' sha- tag.
    #
    # The `g` before the sha is load-bearing, not decoration (it is the same one
    # `git describe` uses). Semver forbids leading zeroes in a *numeric* prerelease
    # identifier, and a 7-character sha prefix is all digits about 3.6% of the time -- so
    # a bare ${SHA:0:7} makes the version invalid on a small fraction of commits, and the
    # CLI then refuses to publish. A leading letter forces it to be an alphanumeric
    # identifier, where leading zeroes are fine.
    version="0.0.0-main.g${SHA:0:7}"
    image_tag=latest
fi

for f in src/*/devcontainer-template.json; do
    # imageTag is stamped as well as the version: the template's whole job is to point a
    # consumer at an image, so a release should hand out a template pinned to the image
    # built in the same run rather than one that floats to whatever `latest` becomes.
    jq --arg v "$version" --arg t "$image_tag" \
        '.version = $v
         | if .options.imageTag then .options.imageTag.default = $t else . end' \
        "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    printf 'stamped %s: version=%s imageTag=%s\n' "$f" "$version" "$image_tag" >&2
done

printf 'version=%s\nimage_tag=%s\n' "$version" "$image_tag"
