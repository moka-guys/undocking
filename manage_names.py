#!/usr/bin/env python

import os
import sys
import json
from collections import defaultdict
from argparse import ArgumentParser


def amend_registry(filename, registry, root):
    pass


def main(root, registry, write=False, show=False):
    name_digest = defaultdict(list)

    # walk through directory tree from root
    print('Checking image manifests...', file=sys.stderr)
    for dirpath, dirnames, filenames in os.walk(root):
        for filename in filenames:
            if filename == 'manifest.json':
                filepath = os.path.join(dirpath, filename)
                # print(filepath)
                digest = dirpath.split('/')[-1]
                # read json file
                with open(filepath) as f:
                    data = json.load(f)
                    for image in data:
                        new_tags = []
                        for tag in image["RepoTags"]:
                            new_tags.append(tag)
                            r, t = tag.split("/")
                            if registry and not r == registry:
                                new_tags.append(registry + "/" + t)
                            # add to conflict dict
                            name_digest[tag].append(digest)
                        image["RepoTags"] = new_tags
                # write json file
                if write:
                    with open(filepath, 'w') as f:
                        json.dump(data, f, indent=4, sort_keys=True)

    if show:
        for name, digests in name_digest.items():
            for digest in digests:
                print("{}\t{}".format(name, digest))

    print('Checking for conflicts...', file=sys.stderr)
    for name, digests in name_digest.items():
        if len(digests) > 1:
            print("Conflict: {} has multiple digests: {}".format(name, digests), file=sys.stderr)        
    print('Done!', file=sys.stderr)


if __name__=='__main__':
    # parse command line arguments with argparse
    argparser = ArgumentParser(description="Add registry to manifest.json files and report conflicts")
    argparser.add_argument('--add', help='registry to add', default=None)
    argparser.add_argument('--show', help='Show image name to digest mappings', default=False, action='store_true')
    argparser.add_argument('--write', help='write changes to manifest', default=False, action='store_true')
    argparser.add_argument('--root', help='root directory of images', default='images')
    args = argparser.parse_args()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.root)

    main(root, args.add, args.write, args.show)
