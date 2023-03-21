#!/bin/bash

for TAR in $(find blobs -type f -name "layer.tar"); do
    echo "Checking $TAR..."
    tar -tf $TAR > /dev/null
    retVal=$?
    if [ $retVal -ne 0 ]; then
        echo "ERROR: $TAR is corrupt!"
        break
    fi
done
exit $retVal

