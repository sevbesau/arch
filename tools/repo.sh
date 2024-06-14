#!/bin/bash

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

PACKAGES="$SCRIPT_DIR/../pkg"
CHROOT="$SCRIPT_DIR/../root"
REPO="$SCRIPT_DIR/../repo"
REPO_DB="$REPO/sevbesau.db.tar.gz"

print_help() {
    echo -e "ERROR: $1"
    echo -e "\nManage the package db for the pacman repository"
    echo "  add-all: adds all the packages to the package db and runs sync"
    echo "  add <path-to-package.tar.zst>: adds the package to the package db and runs sync"
    echo "  remove <pkg-name>: removes the package from the package db and runs sync"
    echo "  sync: syncronize local package db with hosted package db"
    echo "  help: print this message"
}

# Create a chroot env to build packages in
make-chroot() {
    mkdir -p "$CHROOT"
    [[ -d "$CHROOT/root" ]] || mkarchroot -C /etc/pacman.conf "$CHROOT/root" base base-devel
}

# Build a single package
build-package() {
    make-chroot
    pushd pkg/"$1"
    makechrootpkg -cur "$CHROOT"
    mv ./*.pkg.tar.zst "$REPO"
    popd
}

# Build all packages
build-all() {
    for pkg in "$PACKAGES"/*/; do
        echo "$pkg"
        # build-package "$pkg"
    done
}

sync-git() {
    # Update local git repo
    echo "Updating local repo"
    git push

    # Pull changes on file server
    echo "Updating remote repo"
    ssh root@arch.sevbesau.xyz 'cd /var/www/arch.sevbesau.xyz; git pull'
}

sync-packages() {
    # Sending packages to server
    echo "Uploading packages to remote repo"
    pushd repo
    zip -r packages.zip *.pkg.tar.zst
    scp packages.zip arch-repo:/var/www/arch.sevbesau.xyz/repo
    ssh arch-repo -f 'cd /var/www/arch.sevbesau.xyz/repo; unzip -o packages.zip && rm packages.zip'
    rm packages.zip
    popd
}

sync-package() {
    # Sending package to server
    echo "Uploading $1 to remote repo"
    pushd repo
    zip -r packages.zip ${1}*.pkg.tar.zst
    scp packages.zip arch-repo:/var/www/arch.sevbesau.xyz/repo
    ssh arch-repo -f 'cd /var/www/arch.sevbesau.xyz/repo; unzip -o packages.zip && rm packages.zip'
    rm packages.zip
    popd
}

commit-repo() {
    git add repo/*
    git commit -m "$1"
}

# Pull down all files stored in lfs
pull-lfs() {
    git lfs fetch --all
    git lfs pull
}

# Add all packages to the repo db
add-all() {
    pull-lfs
    repo-add $REPO_DB repo/*.pkg.tar.zst
    commit-repo "updated package db"
}

# Add a single package to the repo db
add() {
    pull-lfs
    repo-add $REPO_DB repo/${1}*.pkg.tar.zst
    commit-repo "added $1 to the package db"
}

# Remove a package from the repo db
remove() {
    repo-remove $REPO_DB repo/${1}*.pkg.tar.zst
    commit-repo "removed $1 from the package db"
}

BUILD=false
BUILD_ALL=false
ADD_PACKAGE=false
ADD_ALL_PACKAGES=false
REMOVE_PACKAGE=false
SYNC=false
SYNC_ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--build) BUILD=true; shift ;;
        -B|--buildall) BUILD_ALL=true; shift ;;
        -a|--add) ADD_PACKAGE=true; shift ;;
        -A|--addall) ADD_ALL_PACKAGES=true; shift ;;
        -r|--remove) REMOVE_PACKAGE=true; shift ;;
        -s|--sync) SYNC=true; shift ;;
        -S|--syncall) SYNC_ALL=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        -*) print_help "Unrecognized parameter: '$1'"; exit 1 ;;
        *) PACKAGE="$1"; shift ;;
    esac
done

if $BUILD; then
    [ -z "$PACKAGE" ] && print_help "No package specified" && exit 1
    build-package "$PACKAGE"
fi

#if $BUILD_ALL; then
#    build-all
#fi

if $ADD_PACKAGE; then
    [ -z "$PACKAGE" ] && print_help "No package specified" && exit 1
    add "$PACKAGE"
fi

if $ADD_ALL_PACKAGES; then
    add_all
fi

if $REMOVE_PACKAGE; then
    [ -z "$PACKAGE" ] && print_help "No package specified" && exit 1
    remove "$PACKAGE"
fi

if $SYNC; then
    [ -z "$PACKAGE" ] && print_help "No package specified" && exit 1
    sync-git
    sync-package "$PACKAGE"
fi

if $SYNC_ALL; then
    sync-git
    sync-packges
fi

exit 0
