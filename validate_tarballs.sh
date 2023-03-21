#!/bin/bash

echo "Geting local image names..."
LOCAL_IMAGE_TAGS=($(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>"))
# loop over image tarballs, load, run and remove
for TARBALL in $(find tarballs -type f -name "*.tar.xz"); do
    echo "Getting image tags for $(basename $TARBALL .tar.xz)..."
    TARBALL_IMAGE_TAGS=($(tar xfO $TARBALL manifest.json | jq -r '.[]|.RepoTags[]'))
    echo "Checking for intersection..."
    INTERSECTION=($(echo "${LOCAL_IMAGE_TAGS[@]} ${TARBALL_IMAGE_TAGS[@]}" | sed 's/ /\n/g' | sort | uniq -d))
    echo $INTERSECTION
    # if intersection is empty, load, run and remove
    if [ ${#INTERSECTION[@]} -eq 0 ]; then
        echo "[1] Loading $TARBALL..."
        docker load -i $TARBALL
        echo "[2] Running $TARBALL..."
        docker run --rm ${TARBALL_IMAGE_TAGS[0]}
        echo "[3] Removing $TARBALL tags..."
        for TAG in $TARBALL_IMAGE_TAGS; do
            docker rmi $TAG
        done
    else
        echo "Skipping $TARBALL (will not overwrite existing local image)..."
    fi
done