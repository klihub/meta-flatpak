include ../meta/recipes-core/images/core-image-minimal.bb
inherit flatpak-image

SUMMARY = "Flatpak runtime image for the target device."

# Pull in openssh server.
IMAGE_FEATURES_append = " ssh-server-openssh"

# Pull in flatpak and its dependencies (+ terminfo and certificate files).
IMAGE_INSTALL_append = " \
    systemd flatpak flatpak-utils flatpak-fake-runtime \
    ca-certificates ncurses-terminfo \
"
