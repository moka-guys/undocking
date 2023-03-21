#!/bin/bash

# Example for the Docker Hub V2 API
# Returns all images and tags associated with a Docker Hub organization account.
# Requires 'jq': https://stedolan.github.io/jq/

# set username, password, and organization via environment variables
# DHUSER=""
# DHPASS=""

set -e

# get token
TOKEN=$(curl -s -H "Content-Type: application/json" -X POST -d '{"username": "'${DHUSER}'", "password": "'${DHPASS}'"}' https://hub.docker.com/v2/users/login/ | jq -r .token)
# loop over command line arguments
for ORG in "$@"; do
  # get list of repositories
  REPO_LIST=$(curl -s -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/${ORG}/?page_size=100 | jq -r '.results|.[]|.name')
  # output images & tags
  for i in ${REPO_LIST}
  do
    # tags
    IMAGE_TAGS=$(curl -s -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/${ORG}/${i}/tags/?page_size=100 | jq -r '.results|.[]|.name')
    for j in ${IMAGE_TAGS}
    do
      echo "${ORG}/${i}:${j}"
    done
  done
done
