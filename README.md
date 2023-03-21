# undocking
Scripts to move images off docker hub for backup and transfer to other registry.
These script do not require a docker install and aim to download the minimal amount of data (layers are shared).


## Limitations
Docker Hub has a rate limit which can prevent the download of all image manifests and layers in one go. If the downbload fails with a 429 error, one can wait 6h and retry. The scripts will automatically check existing downloads and resume where necessary.

As the docker hub APIs do not allow for byte range downloads, an interrupted download can lead to an incomplete file. The `check_tarballs.sh` will test all tar files in the image directories for completeness. It is still recommended to validate any backed up images with a test restore and unit test (if available).

## Goals

- Create an image manifest for all images in a docker registry
- Create backups from docker iamges in given registry organisations
- Move (retag and upload) images to new registry


## Workflow

1. Set docker login credentials
2. Get list of images per org. Create image manifest
3. Download image layers
4. Check tarballs for integrity
5. (optional) Add image names for upload to new registry
6. Assemble images into `tar` archives
7. (optional) Validate by importing locally and running a unit test
8. (optional) Push images to new registry

### Set docker credentials
Set your docker credentials as `DHUSER` and `DHPASS` environment variables. 

### Create image manifest
Creates the image manifest for a list of organisations.

`image_manifest.sh [ORG1] ([ORG2] ...) > manifest.txt`

### Get image layers
Downloads image layers for an image (and amends the image manifest if image digest is shared with another image).

`download_layers.sh [IMAGE_NAME]`

or for batch processing from a list of repositories

`cat manifext.txt | xargs -L1 download_layers.sh`

### Check Tarballs

This simply check if an image layer tarball is complete. It does _not_ check integrity with a checksum.

`check_tarballs.sh`

### Add registry

This adds tags to the downloaded image manifests. It assumes images manifests are stored in the `images/` directory.
This will edit manifest.json in place. To highlight potential tag conflicts, run without the `--write` flag.

`manage_names.py --add [REGISTRY_URL] --write`

### Pack images

Packs image layers into tar files according to image `manifest.json`.

`pack_images.sh`

### Validate images
This process is not automated as unit tests for an image are not implicitily defined. The follow steps are recommended:

1. Import image into local store with `docker load < image.tar`
2. Run the imported image (test)
3. Delete the image from local store with `docker rmi`

Steps 1 and 3 can be tested with the `validate_tarballs.sh`.
> NB: This script will only process the validation for images that are not already present locally.

### Push images back to registry

***Not implemented***

This pushes the images to th remote registries with a _load-push-remove_ cycle.

`push_images.sh`