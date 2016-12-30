#!/bin/bash

# Print help on usage.

print_usage () {
    echo "usage: $0 -i <image-tarball>|-b <builddir> -t runtime|sdk [ options ]"
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
    echo "    -r <repo>       flatpak repository path"
    echo "    -A <arch>       CPU architecture of image architecture"
    echo "    -V <version>    image version"
    echo "    -m <metadata>   image metadata to use"
    echo "    -b <builddir>   builddir to search for images based on type"
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
            --arch|-A)
                IMG_ARCH=$2
                shift 2
                ;;
            --version|-V)
                IMG_VERSION=$2
                shift 2
                ;;
            --metadata|-m)
                IMG_METADATA=$2
                shift 2
                ;;
            --image|-i)
                IMG_TARBALL=$2
                shift 2
                ;;
            --builddir|-b)
                IMG_BUILDDIR=$2
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

    case $IMG_ARCH in
        x86_64) QEMUARCH=qemux86-64;;
        x86)    QEMUARCH=qemux86;;
        *)      QEMUARCH=qemu$IMG_ARCH;;
    esac

    if [ -z "$IMG_TARBALL" -a -n "$IMG_BUILDDIR" -a -n "$IMG_TYPE" ]; then
        IMG_TARBALL="$IMG_BUILDDIR/tmp/deploy/images/$QEMUARCH"
        IMG_TARBALL="$IMG_TARBALL/flatpak-$IMG_TYPE-image-$QEMUARCH.tar.bz2"
    fi


    if [ -z "$IMG_TARBALL" ]; then
        echo "Missing image (tarball) argument."
        exit 1
    fi

    if [ -z "$IMG_TYPE" ]; then
        case $IMG_TARBALL in
            *runtime*) IMG_TYPE=runtime;;
            *sdk*)     IMG_TYPE=sdk;;
            *)
                echo "Image type (runtime, sdk) not given and could not be" \
                     "guessed."
                exit 1
                ;;
        esac
    fi

    case $IMG_TYPE in
        runtime)
            BRANCH=runtime/org.yocto.BasePlatform/$IMG_ARCH/$IMG_VERSION
            ;;
        sdk)
            BRANCH=runtime/org.yocto.BaseSdk/$IMG_ARCH/$IMG_VERSION
            ;;
    esac

    if [ -z "$IMG_METADATA" ]; then
        IMG_METADATA=metadata.$IMG_TYPE
        if [ ! -f $IMG_METADATA -a ! $IMG_METADATA.in ]; then
            echo "Missing image metadata ($IMG_METADATA[.in])."
            exit 1
        fi
    fi

    SYSROOT=.tmp.$IMG_TYPE.sysroot
    REPO_METADATA=.tmp.metadata.$IMG_TYPE
}

# Create image metadata file for the repository.
metadata_prepare () {
    if [ ! -f $IMG_METADATA -a -f $IMG_METADATA.in ]; then
        cat $IMG_METADATA.in | \
            sed "s/@ARCH@/$IMG_ARCH/g;s/@VERSION@/$IMG_VERSION/g" \
                > $REPO_METADATA
    else
        cp $IMG_METADATA $REPO_METADATA
    fi
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
    # Notes:
    #     If flatpak build-export did take --owner-{uid,gid} arguments and
    #     pass it forward to ostree, we could directly use it here without
    #     doing path-relocation or filtering using tar, like this:
    #
    #       cd $SYSROOT, tar -xjf $IMG_TARBALL
    #       flatpak build-export --runtime -s "$IMG_TYPE $VERSION" \
    #           --gpg-home=$GPG_HOME --gpg-sign=$GPG_KEY \
    #           --owner-uid=0 --owner-gid=0 --no-xattrs \
    #           $REPO_PATH $SYSROOT $BRANCH
    #
    #     Now we have to use the (hopefully) equivalent low-level ostree
    #     commands instead...
    #

    echo "* Creating image sysroot ($SYSROOT) from $IMG_TARBALL..."
    mkdir -p $SYSROOT
    tar --transform "s,^./usr,$SYSROOT/files,S" \
        --transform "s,^./etc,$SYSROOT/file/etc,S" \
        --exclude './[!eu]*' -xjf $IMG_TARBALL;
    find $SYSROOT -type f -exec chmod u+r {} \;
    mv $REPO_METADATA $SYSROOT/metadata
    echo "* Populating repository with $IMG_TYPE image..."
    ostree --repo=$REPO_PATH commit \
           --gpg-homedir=$GPG_HOME --gpg-sign=$GPG_KEY \
           --owner-uid=0 --owner-gid=0 --no-xattrs \
           -s "$IMG_TYPE $IMG_VERSION" \
           -b "Commit of $IMG_TARBALL into the repository." \
           --branch=$BRANCH $SYSROOT

    echo "* Cleaning up $SYSROOT..."
    rm -rf $SYSROOT
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
    tar -tjf $IMG_TARBALL | \
        grep 'lib/lib.*\.so\.' | sed 's#^\./#/#g' > $IMG_LIBS
}


#########################
# main script

REPO_PATH=flatpak.repo
GPG_HOME=.gpg.flatpak
GPG_KEY=repo-signing@key
IMG_ARCH=x86_64
IMG_VERSION=0.0.1
IMG_METADATA=""
IMG_TARBALL=""
IMG_TYPE=""
IMG_LIBS=""

parse_command_line $*

echo "image:      $IMG_TARBALL"
echo "image type: $IMG_TYPE"
sleep 3

set -e

metadata_prepare
repo_init
repo_populate
repo_update_summary
generate_lib_list
