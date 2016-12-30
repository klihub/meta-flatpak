#!/bin/bash

# Print help on usage.
print_usage () {
    echo "usage: $0 -D <image-dir> -t runtime|sdk [ options ]"
    echo ""
    echo "Take a runtime or SDK image tarball, commit it to a flatpak/ostree"
    echo "repository, and update the repository summary. The repository is in"
    echo "archive-z2 format, suitable to be exported over HTTP for clients to"
    echo "fetch data from."
    echo ""
    echo "The image is either specified using the --image <tarball> argument or"
    echo "by providing the path to the Yocto build directory and the image type"
    echo "using the --builddir <path> and --type sdk|runtime arguments."
    echo ""
    echo "The other possible options are:"
    echo "    -r <repo>       path to flatpak repository to populate"
    echo "    -A <arch>       CPU architecture of the image"
    echo "    -V <version>    image version"
    echo "    -D <image-dir>  image sysroot directory"
    echo "    -t sdk|runtime  image type"
    echo "    -l <lib-list>   generate provided library list file"
    echo "    -H <gpg-dir>    GPG homed directory with keyring"
    echo "    -K <keyid>      GPG key id used to sign the repository"
    echo "    -h              show this help"
}

# Parse the command line.
parse_command_line () {
    while [ -n "$1" ]; do
        case $1 in
            --repo|-r)
                REPO_PATH=$2
                shift 2
                ;;
            --image-dir|-D)
                IMG_SYSROOT=$2
                shift 2
                ;;
            --tmp-dir|-T)
                IMG_TMPDIR=$2
                shift 2
                ;;
            --arch|-A)
                IMG_ARCH=$2
                shift 2
                ;;
            --version|-V)
                IMG_VERSION=$2
                shift 2
                ;;
            --type|-t)
                IMG_TYPE=$2
                shift 2
                ;;
            --libs|-l)
                IMG_LIBS=$2
                shift 2
                ;;
            --gpg-homedir|--gpg-home|-H)
                GPG_HOME=$2
                shift 2
                ;;
            --gpg-key|-K)
                GPG_KEY=$2
                shift 2
                ;;

            --help|-h)
                print_usage
                exit 0
                ;;

            *)
                echo "Unknown command line option/argument $1."
                print_usage
                exit 1
                ;;
        esac
    done

    REPO_ARCH=${IMG_ARCH#qemu}
    REPO_ARCH=${REPO_ARCH//-/_}
    echo "REPO_ARCH: $REPO_ARCH"

    case $IMG_ARCH in
        qemux86-64) REPO_ARCH=x86_64;    QEMU_ARCH=qemux86-64;;
        qemux86)    REPO_ARCH=x86;       QEMU_ARCH=qemux86;;
        x86_64)     REPO_ARCH=x86_64;    QEMU_ARCH=qemux86-64;;
        x86)        REPO_ARCH=x86;       QEMU_ARCH=qemux86;;
        *)          REPO_ARCH=$IMG_ARCH; QEMU_ARCH=$IMG_ARCH;;
    esac

    if [ -z "$IMG_TYPE" ]; then
        echo "Image type not given, assuming 'sdk'..."
        IMG_TYPE=sdk
    fi

    case $IMG_TYPE in
        runtime)
            REPO_BRANCH=runtime/$REPO_ORG.BasePlatform/$REPO_ARCH/$IMG_VERSION
            ;;
        sdk)
            REPO_BRANCH=runtime/$REPO_ORG.BaseSdk/$REPO_ARCH/$IMG_VERSION
            ;;
    esac

    if [ -z "$IMG_SYSROOT" ]; then
        echo "Image sysroot directory not given."
        exit 1
    fi

    SYSROOT=$IMG_TMPDIR/$IMG_TYPE.sysroot
    REPO_METADATA=$SYSROOT/metadata
}

# Create image metadata file for the repository.
metadata_generate () {
    echo "* Generating $IMG_TYPE image metadata ($REPO_METADATA)..."

    (echo "[Runtime]"
     if [ "$IMG_TYPE" != "sdk" ]; then
         echo "name=$REPO_ORG.BasePlatform"
     else
         echo "name=$REPO_ORG.BaseSdk"
     fi
     echo "runtime=$REPO_ORG.BasePlatform/$REPO_ARCH/$REPO_VERSION"
     echo "sdk=$REPO_ORG.BaseSdk/$REPO_ARCH/$REPO_VERSION" ) > $REPO_METADATA
}

# Populate temporary sysroot with flatpak-translated path names.
sysroot_populate () {
    echo "* Creating flatpak-relocated sysroot ($SYSROOT) from $IMG_SYSROOT..."
    mkdir -p $SYSROOT
    bsdtar -C $IMG_SYSROOT -cf - ./usr ./etc | \
        bsdtar -C $SYSROOT \
            -s ":^./usr:./files:S" \
            -s ":^./etc:./files/etc:S" \
            -xvf -
}

# Clean up temporary sysroot.
sysroot_cleanup () {
    echo "* Cleaning up $SYSROOT..."
    rm -rf $SYSROOT
}

# Initialize flatpak/OSTree repository, if necessary.
repo_init () {
    if [ ! -d $REPO_PATH ]; then
        echo "* Initializing repository $REPO_PATH..."
        mkdir -p $REPO_PATH
        ostree --repo=$REPO_PATH init --mode=archive-z2
    else
        echo "* Using existing repository $REPO_PATH..."
    fi
}

# Populate the repository.
repo_populate () {
    # workaround: OSTree can't handle files with no read permission
    echo "* Fixup permissions for OSTree..."
    find $SYSROOT -type f -exec chmod u+r {} \;

    echo "* Populating repository with $IMG_TYPE image..."
    ostree --repo=$REPO_PATH commit \
           --gpg-homedir=$GPG_HOME --gpg-sign=$GPG_KEY \
           --owner-uid=0 --owner-gid=0 --no-xattrs \
           -s "$IMG_TYPE $IMG_VERSION" \
           -b "Commit of $IMG_TARBALL into the repository." \
           --branch=$REPO_BRANCH $SYSROOT
}

# Update repository summary.
repo_update_summary () {
    echo "* Updating repository summary..."
    ostree --repo=$REPO_PATH summary -u \
           --gpg-homedir=$GPG_HOME --gpg-sign=$GPG_KEY
}

# Generate list of libraries provided by the image.
generate_lib_list () {
    [ -z "$IMG_LIBS" ] && return 0

    echo "* Generating list of provided libraries..."
    (cd $IMG_SYSROOT; find . -type f) | \
        grep 'lib/lib.*\.so\.' | sed 's#^\./#/#g' > $IMG_LIBS
}


#########################
# main script

REPO_ORG=iot.refkit

REPO_PATH=flatpak.repo
GPG_HOME=.gpg.flatpak
GPG_KEY=iot-refkit@key

IMG_TMPDIR=/tmp
IMG_ARCH=x86_64
IMG_VERSION=0.0.1
IMG_SYSROOT=""
IMG_TYPE=""
IMG_LIBS=""

parse_command_line $*

echo "image root: $IMG_SYSROOT"
echo "      type: $IMG_TYPE"
echo "      arch: $IMG_ARCH"
echo " repo arch: $REPO_ARCH"
echo "   version: $IMG_VERSION"
echo " qemu arch: $QEMU_ARCH"

set -e

repo_init
sysroot_populate
metadata_generate
repo_populate
repo_update_summary
#generate_lib_list
sysroot_cleanup
