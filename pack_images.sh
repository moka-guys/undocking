#!/bin/bash

ROOTDIR=images
MANIFEST=manifest.json
TARDIR=tarballs

for FILE in $(find $ROOTDIR -type f -maxdepth 2 -name $MANIFEST); do
    DIR=$(dirname $FILE)
    ABSDIR=$(realpath $DIR)
    ABSTAR=$(realpath $TARDIR)
    DIGEST=$(basename $DIR)

    echo "SAVING $DIGEST to $TARDIR ($DIGEST)..."
    tar -chC $ABSDIR . | xz -cz -T0 > $ABSTAR/$DIGEST.tar.xz
done