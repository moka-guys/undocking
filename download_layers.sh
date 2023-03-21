#!/usr/bin/env bash
set -eo pipefail

# Simplified download of docker image layers of HTTP(S) ports and autmomatic import

# check if essential commands are in our PATH
for cmd in curl jq go; do
	if ! command -v $cmd &> /dev/null; then
		echo >&2 "error: \"$cmd\" not found!"
		exit 1
	fi
done

usage() {
	echo "usage: $0 image[:tag][@digest] ..."
	echo "       $0 hello-world:latest@sha256:8be990ef2aeb16dbcb9271ddfe2610fa6658d13f6dfb8bc72074cc1ca36966a7"
	[ -z "$1" ] || exit "$1"
}

# get absolute paths of image and blob directories
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
imageDir="${SCRIPT_DIR}/images" # root dir for building tar in
blobDir="${SCRIPT_DIR}/blobs" # root dir for storing blobs

# create image directory
[ $# -gt 0 -a "$imageDir" ] || usage 2 >&2
mkdir -p "$imageDir"

# hacky workarounds for Bash 3 support (no associative arrays)
images=()
manifestJsonEntries=()
newlineIFS=$'\n'
registryBase='https://registry-1.docker.io'
authBase='https://auth.docker.io'
authService='registry.docker.io'

# Fetch an image layer blob
fetch_blob() {
	local token="$1"
	shift
	local image="$1"
	shift
	local digest="$1"
	shift
	local targetFile="$1"
	shift
	local curlArgs=("$@")

	local curlHeaders="$(
		curl -S "${curlArgs[@]}" \
			-H "Authorization: Bearer $token" \
			"$registryBase/v2/$image/blobs/$digest" \
			-o "$targetFile" \
			-D-
	)"
	curlHeaders="$(echo "$curlHeaders" | tr -d '\r')"
	if grep -qE "^HTTP/[0-9].[0-9] 3" <<< "$curlHeaders"; then
		rm -f "$targetFile"

		local blobRedirect="$(echo "$curlHeaders" | awk -F ': ' 'tolower($1) == "location" { print $2; exit }')"
		if [ -z "$blobRedirect" ]; then
			echo >&2 "error: failed fetching '$image' blob '$digest'"
			echo "$curlHeaders" | head -1 >&2
			return 1
		fi

		curl -fSL "${curlArgs[@]}" \
			"$blobRedirect" \
			-o "$targetFile"
	fi
}

# handle 'application/vnd.docker.distribution.manifest.v2+json' manifest
handle_single_manifest_v2() {
	local manifestJson="$1"
	shift

	local configDigest="$(echo "$manifestJson" | jq --raw-output '.config.digest')"
	local imageId="${configDigest#*:}" # strip off "sha256:"

	# fetch config
	local configFile="$imageId.json"
	fetch_blob "$token" "$image" "$configDigest" "$dir/$configFile" -s

	local layersFs="$(echo "$manifestJson" | jq --raw-output --compact-output '.layers[]')"
	local IFS="$newlineIFS"
	local layers=($layersFs)
	unset IFS

	echo "Downloading '$imageIdentifier' (${#layers[@]} layers)..."
	local layerId=
	local layerFiles=()
	for i in "${!layers[@]}"; do
		local layerMeta="${layers[$i]}"

		# get the layer's media type and digest
		local layerMediaType="$(echo "$layerMeta" | jq --raw-output '.mediaType')"
		local layerDigest="$(echo "$layerMeta" | jq --raw-output '.digest')"

		# save the previous layer's ID
		local parentId="$layerId"
		# create a new fake layer ID based on this layer's digest and the previous layer's fake ID
		# this accounts for the possibility that an image contains the same layer twice (and thus has a duplicate digest value)
		layerId="$(echo "$parentId"$'\n'"$layerDigest" | shasum -a 256 | cut -d' ' -f1)"

		echo "Handling layer $((i+1))/${#layers[@]}: $layerId"

		mkdir -p "$dir/$layerId"
		echo '1.0' > "$dir/$layerId/VERSION"

		if [ ! -s "$dir/$layerId/json" ]; then
			local parentJson="$(printf ', parent: "%s"' "$parentId")"
			local addJson="$(printf '{ id: "%s"%s }' "$layerId" "${parentId:+$parentJson}")"
			# this starter JSON is taken directly from Docker's own "docker save" output for unimportant layers
			jq "$addJson + ." > "$dir/$layerId/json" <<- 'EOJSON'
				{
					"created": "0001-01-01T00:00:00Z",
					"container_config": {
						"Hostname": "",
						"Domainname": "",
						"User": "",
						"AttachStdin": false,
						"AttachStdout": false,
						"AttachStderr": false,
						"Tty": false,
						"OpenStdin": false,
						"StdinOnce": false,
						"Env": null,
						"Cmd": null,
						"Image": "",
						"Volumes": null,
						"WorkingDir": "",
						"Entrypoint": null,
						"OnBuild": null,
						"Labels": null
					}
				}
			EOJSON
		fi

		case "$layerMediaType" in
			application/vnd.docker.image.rootfs.diff.tar.gzip)
				local layerTar="$layerId/layer.tar"
				# echo $(ls -l $blobDir/$layerTar)
				layerFiles=("${layerFiles[@]}" "$layerTar")
				if [ -e "$blobDir/$layerTar" ]; then
					echo "skipping existing ${layerId:0:12}"
					continue
				else
					local token="$(curl -fsSL "$authBase/token?service=$authService&scope=repository:$image:pull" | jq --raw-output '.token')"
					mkdir -p "$blobDir/$layerId"
					# download blob into blob directory and link into image dir (maximise reuse or large layer blobs)
					fetch_blob "$token" "$image" "$layerDigest" "$blobDir/$layerTar" --progress-bar
				fi
				# link the blob into the image directory
				rm -f "$dir/$layerTar"	
				ln -s "$blobDir/$layerTar" "$dir/$layerTar"
				;;

			*)
				echo >&2 "error: unknown layer mediaType ($imageIdentifier, $layerDigest): '$layerMediaType'"
				exit 1
				;;
		esac
	done

	# change "$imageId" to be the ID of the last layer we added (needed for old-style "repositories" file which is created later -- specifically for older Docker daemons)
	imageId="$layerId"

	# munge the top layer image manifest to have the appropriate image configuration for older daemons
	local imageOldConfig="$(jq --raw-output --compact-output '{ id: .id } + if .parent then { parent: .parent } else {} end' "$dir/$imageId/json")"
	jq --raw-output "$imageOldConfig + del(.history, .rootfs)" "$dir/$configFile" > "$dir/$imageId/json"

	local manifestJsonEntry="$(
		echo '{}' | jq --raw-output '. + {
			Config: "'"$configFile"'",
			RepoTags: ["'"${image#library\/}:$tag"'"],
			Layers: '"$(echo '[]' | jq --raw-output ".$(for layerFile in "${layerFiles[@]}"; do echo " + [ \"$layerFile\" ]"; done)")"'
		}'
	)"
	manifestJsonEntries=("${manifestJsonEntries[@]}" "$manifestJsonEntry")

}

### main loop
imageTag="$1"
shift
image="${imageTag%%[:@]*}"
imageTag="${imageTag#*:}"
digest="${imageTag##*@}"
tag="${imageTag%%@*}"

# add prefix library if passed official image
if [[ "$image" != *"/"* ]]; then
	image="library/$image"
fi

imageFile="${image//\//_}" # "/" can't be in filenames :)
# echo $imageFile
# exit 1

# get access token
token="$(curl -fsSL "$authBase/token?service=$authService&scope=repository:$image:pull" | jq --raw-output '.token')"

# get manifest
manifestJson="$(
	curl -fsSL \
		-H "Authorization: Bearer $token" \
		-H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
		-H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
		-H 'Accept: application/vnd.docker.distribution.manifest.v1+json' \
		"$registryBase/v2/$image/manifests/$digest"
)"



if [ "${manifestJson:0:1}" != '{' ]; then
	echo >&2 "error: /v2/$image/manifests/$digest returned something unexpected:"
	echo >&2 "  $manifestJson"
	exit 1
fi

imageNameTag="$image:$tag"
imageIdentifier="$imageNameTag@$digest"

# download accoding to schemaVersion
schemaVersion="$(echo "$manifestJson" | jq --raw-output '.schemaVersion')"
case "$schemaVersion" in
	2)
		mediaType="$(echo "$manifestJson" | jq --raw-output '.mediaType')"

		case "$mediaType" in
			application/vnd.docker.distribution.manifest.v2+json)
				digestString="$(echo "$manifestJson" | jq --raw-output '.config.digest')"
				echo "Checking ${digestString}"
				dir="${imageDir}/${digestString:7:12}"
				mkdir -p "${dir}"
				handle_single_manifest_v2 "$manifestJson"
				;;
			application/vnd.docker.distribution.manifest.list.v2+json)
				layersFs="$(echo "$manifestJson" | jq --raw-output --compact-output '.manifests[]')"
				IFS="$newlineIFS"
				layers=($layersFs)
				unset IFS

				found=""
				# parse first level multi-arch manifest
				for i in "${!layers[@]}"; do
					layerMeta="${layers[$i]}"
					maniArch="$(echo "$layerMeta" | jq --raw-output '.platform.architecture')"
					if [ "$maniArch" = "$(go env GOARCH)" ]; then
						digest="$(echo "$layerMeta" | jq --raw-output '.digest')"
						dir="${imageDir}/${digest:7:12}"
						mkdir -p "${dir}"
						# get second level single manifest
						submanifestJson="$(
							curl -fsSL \
								-H "Authorization: Bearer $token" \
								-H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
								-H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
								-H 'Accept: application/vnd.docker.distribution.manifest.v1+json' \
								"$registryBase/v2/$image/manifests/$digest"
						)"
						handle_single_manifest_v2 "$submanifestJson"
						found="found"
						break
					fi
				done
				if [ -z "$found" ]; then
					echo >&2 "error: manifest for $maniArch is not found"
					exit 1
				fi
				;;
			*)
				echo >&2 "error: unknown manifest mediaType ($imageIdentifier): '$mediaType'"
				exit 1
				;;
		esac
		;;
	*)
		echo >&2 "error: unknown manifest schemaVersion ($imageIdentifier): '$schemaVersion'"
		exit 1
		;;
esac

# if manifest.json exists, add an entry for the image we just downloaded
if [ -f "$dir/manifest.json" ]; then
	# check if current tag exists else add
	tagIndex=$(cat $dir/manifest.json | jq --raw-output --arg TAG $imageNameTag '.[0].RepoTags | index($TAG)')
	if [[ "$tagIndex" != "null" ]]; then
		echo "Tag $imageNameTag already exists ($tagIndex)"
	else
		echo "Adding tag $imageNameTag"
		# add tag to manifest.json
		cat $dir/manifest.json | jq --raw-output --arg TAG $imageNameTag '.[0].RepoTags[.[0].RepoTags | length] += $TAG' > $dir/amended_manifest.json && mv $dir/amended_manifest.json $dir/manifest.json
	fi
elif [ "${#manifestJsonEntries[@]}" -gt 0 ]; then
	echo '[]' | jq --raw-output ".$(for entry in "${manifestJsonEntries[@]}"; do echo " + [ $entry ]"; done)" > "$dir/manifest.json"
fi

# import image
#echo "IMPORTING $dir ..."
#tar -cC "$dir" . | docker load

# pack downloaded image into tar file
# echo "SAVING $image to $dir ($digestString)..."
# tar -czhC $dir . > $imageDir/${digestString:7:12}.tgz
#&& rm -rf $dir

# remove temporary directory
#echo "Removing ${imageDir}..."
#rm -rf "$imageDir"

echo "DONE"
echo "${digestString}"
