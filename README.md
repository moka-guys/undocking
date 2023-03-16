# undocking
Scripts to move images off docker hub for backup and transfer to other registry

## Goals

- Create an image manifest for all images in a docker registry
- Create backups from docker iamges in given registry organisations
- Move (retag and upload) images to new registry


## Workflow

1. Download images into director as tar files
2. Import images locally
3. Retag images
4. Push images to new registry
5. Delete imported images locally
6. Delete images from docker hub

### Create image manifest

`image_manifest.sh [ORG1] [ORG2] ...`

### Backup

`docker_backup.sh [MANIFEST] ...`

### Move to new registry

`move_registry.py`

Not Implemented.


