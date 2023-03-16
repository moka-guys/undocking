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
rm -f "$imageDir"/tags-*.tmp
manifestJsonEntries=()
doNotGenerateManifestJson=
newlineIFS=$'\n'
registryBase='https://registry-1.docker.io'
authBase='https://auth.docker.io'
authService='registry.docker.io'

# https://github.com/moby/moby/issues/33700
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

# check digest (exists if available)
check_digest() {
	if [ "$(docker images --no-trunc $image | grep $digestString | grep -c $digest)" -ne "0" ]; then
		echo "Image ${image}:${digest} (${digestString}) already present"
		echo "${digestString}"
		#docker save $image | gzip > "$imageDir/$image-$digestString.tar.gz"
		exit 0
	fi
}

# handle 'application/vnd.docker.distribution.manifest.v2+json' manifest
handle_single_manifest_v2() {
	local manifestJson="$1"
	shift

	local configDigest="$(echo "$manifestJson" | jq --raw-output '.config.digest')"
	local imageId="${configDigest#*:}" # strip off "sha256:"

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

		local layerMediaType="$(echo "$layerMeta" | jq --raw-output '.mediaType')"
		local layerDigest="$(echo "$layerMeta" | jq --raw-output '.digest')"

		# save the previous layer's ID
		local parentId="$layerId"
		# create a new fake layer ID based on this layer's digest and the previous layer's fake ID
		layerId="$(echo "$parentId"$'\n'"$layerDigest" | shasum -a 256 | cut -d' ' -f1)"
		# this accounts for the possibility that an image contains the same layer twice (and thus has a duplicate digest value)

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
				layerFiles=("${layerFiles[@]}" "$layerTar")
				# TODO figure out why "-C -" doesn't work here
				# "curl: (33) HTTP server doesn't seem to support byte ranges. Cannot resume."
				# "HTTP/1.1 416 Requested Range Not Satisfiable"
				if [ -f "$dir/$layerTar" ]; then
					# TODO hackpatch for no -C support :'(
					echo "skipping existing ${layerId:0:12}"
					continue
				fi
				local token="$(curl -fsSL "$authBase/token?service=$authService&scope=repository:$image:pull" | jq --raw-output '.token')"
				mkdir -p "$blobDir/$layerId"
				fetch_blob "$token" "$image" "$layerDigest" "$blobDir/$layerTar" --progress-bar
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

while [ $# -gt 0 ]; do
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

	imageIdentifier="$image:$tag@$digest"
	
	# download accoding to schemaVersion
	schemaVersion="$(echo "$manifestJson" | jq --raw-output '.schemaVersion')"
	case "$schemaVersion" in
		2)
			mediaType="$(echo "$manifestJson" | jq --raw-output '.mediaType')"

			case "$mediaType" in
				application/vnd.docker.distribution.manifest.v2+json)
					digestString="$(echo "$manifestJson" | jq --raw-output '.config.digest')"
					echo "Checking ${digestString}"
					check_digest "$digestString"	
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
							check_digest "$digest"
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

	echo

	if [ -s "$dir/tags-$imageFile.tmp" ]; then
		echo -n ', ' >> "$dir/tags-$imageFile.tmp"
	else
		images=("${images[@]}" "$image")
	fi
	echo -n '"'"$tag"'": "'"$imageId"'"' >> "$dir/tags-$imageFile.tmp"
done

# build repositories file
echo -n '{' > "$dir/repositories"
firstImage=1
for image in "${images[@]}"; do
	imageFile="${image//\//_}" # "/" can't be in filenames :)
	image="${image#library\/}"

	[ "$firstImage" ] || echo -n ',' >> "$dir/repositories"
	firstImage=
	echo -n $'\n\t' >> "$dir/repositories"
	echo -n '"'"$image"'": { '"$(cat "$dir/tags-$imageFile.tmp")"' }' >> "$dir/repositories"
done
echo -n $'\n}\n' >> "$dir/repositories"

rm -f "$dir"/tags-*.tmp

if [ -z "$doNotGenerateManifestJson" ] && [ "${#manifestJsonEntries[@]}" -gt 0 ]; then
	echo '[]' | jq --raw-output ".$(for entry in "${manifestJsonEntries[@]}"; do echo " + [ $entry ]"; done)" > "$dir/manifest.json"
else
	rm -f "$dir/manifest.json"
fi

# import image
#echo "IMPORTING $dir ..."
#tar -cC "$dir" . | docker load

# pack downloaded image into tar file
echo "SAVING $image to $dir ($digestString)..."
tar -czhC $dir . > $imageDir/${digestString:7:12}.tgz
#&& rm -rf $dir

# remove temporary directory
#echo "Removing ${imageDir}..."
#rm -rf "$imageDir"

echo "DONE"
echo "${digestString}"
