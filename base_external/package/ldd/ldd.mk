##############################################################
#
# LDD
#
##############################################################

# SITE uses the ssh (git@github.com:) form, matching aesd-assignments.mk.
# VERSION is the pinned assignment 7 commit (kernel-6.18-updates, builds on Linux 6.18).
LDD_VERSION = acae6be1e93b2af5052dfe0415bca480be7754d6
LDD_SITE = git@github.com:cu-ecen-aeld/assignment-7-julian-werder.git
LDD_SITE_METHOD = git
LDD_MODULE_SUBDIRS = misc-modules scull

$(eval $(kernel-module))
$(eval $(generic-package))
