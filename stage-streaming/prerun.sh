#!/bin/bash -e

# Standard pi-gen prerun: copy the previous stage's rootfs into this stage's working dir
# so subsequent on_chroot calls see the accumulated state.
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi
