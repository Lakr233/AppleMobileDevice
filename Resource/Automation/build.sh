#!/bin/bash

set -e
cd $(dirname $0)

SCRIPT_DIR=$(pwd)

echo "[i] libimobiledevice static xcframework builder"
echo "[i] by: @Lakr233"
echo "[i] version: 1.1.0"
echo ""

./check.sh

WORKING_DIR=$(pwd)/libimobiledevice-dev
if [ ! -z $1 ]; then
    if [[ $1 != /* ]]; then
        echo "[!] build dir must be absolute path"
        exit 1
    fi
    WORKING_DIR=$1
fi
if [ ! -d $WORKING_DIR ]; then
    mkdir -p $WORKING_DIR
fi
cd $WORKING_DIR
echo "[i] working dir: $WORKING_DIR"

OUTPUT_XCFRAMEWORK=$WORKING_DIR/libimobiledevice.xcframework
if [ ! -z $2 ]; then
    if [[ $2 != /* ]]; then
        echo "[!] output location must be absolute path"
        exit 1
    fi
    if [[ $2 != *.xcframework ]]; then
        echo "[!] output location must ends with .xcframework"
        exit 1
    fi
    OUTPUT_XCFRAMEWORK=$2
fi
echo "[i] output xcframework: $OUTPUT_XCFRAMEWORK"

PKG_CONFIG_PATH_ORIG=$PKG_CONFIG_PATH

# $1 = git source, $2 = git commit (optional), $3 = prefix, $4 = arch
function build_from_git_source() {
    cd $WORKING_DIR

    echo "[+] preparing..."
    if [ ! -d $(basename $1) ]; then
        git clone $1
    fi

    cd $(basename $1)
    git clean -fdx -f 2>1 > /dev/null
    git reset --hard 2>1 > /dev/null
    git fetch --all

    # if $2 is empty or is -, then use the latest commit
    if [ ! -z $2 ] && [ $2 != "-" ]; then
        git checkout $2
    else
        git checkout master || git checkout main
        git pull
    fi

    echo "[+] configuring..."
    export PKG_CONFIG_PATH=$3/lib/pkgconfig:$PKG_CONFIG_PATH_ORIG
    if [ -f autogen.sh ]; then
        arch "-$4" ./autogen.sh --prefix=$3 --without-cython 1> /dev/null
    elif [ -f configure ]; then
        arch "-$4" ./configure --prefix=$3 1> /dev/null
    fi

    echo "[+] building..."
    arch "-$4" make -j$(nproc) 1> /dev/null
    arch "-$4" make install -j$(nproc) 1> /dev/null

    echo "[+] cleaning..."
    git clean -fdx -f 2>1 > /dev/null
    git reset --hard 2>1 > /dev/null
}

TARGET_GIT_SOURCE=(
    https://github.com/openssl/openssl
    https://github.com/libimobiledevice/libplist
    https://github.com/libimobiledevice/libimobiledevice-glue
    https://github.com/libimobiledevice/libusbmuxd
    https://github.com/libimobiledevice/libimobiledevice
)
TARGET_GIT_COMMIT=(
    $(wget -q -O- https://api.github.com/repos/openssl/openssl/releases/latest | jq -r '.tag_name')
    "-"
    "-"
    "-"
    "-"
)

OUTPUT_BINARY_LIST=()
OUTPUT_HEADER_LIST=()

# $1 = arch
function build_all() {
    echo "[+] building for $1..."
    BUILD_PREFIX=$WORKING_DIR/build.$1
    if [ -d $BUILD_PREFIX ]; then
        rm -rf $BUILD_PREFIX
    fi
    mkdir -p $BUILD_PREFIX

    for ((i=0; i<${#TARGET_GIT_SOURCE[@]}; i++)); do
        GIT_URL=${TARGET_GIT_SOURCE[$i]}
        if [ -z $GIT_URL ]; then
            continue
        fi
        GIT_COMMIT=${TARGET_GIT_COMMIT[$i]}
        if [ -z $GIT_COMMIT ]; then
            GIT_COMMIT="-"
        fi
        echo "[+] sending $GIT_URL $GIT_COMMIT"
        build_from_git_source $GIT_URL $GIT_COMMIT $BUILD_PREFIX $1
    done

    OUTPUT_BINARY=$BUILD_PREFIX/libimobiledevice.a
    if [ -f $OUTPUT_BINARY ]; then
        rm -rf $OUTPUT_BINARY
    fi
    echo "[+] linking..."
    ls $BUILD_PREFIX/lib/*.a
    libtool -static -o $OUTPUT_BINARY $BUILD_PREFIX/lib/*.a
    lipo -archs $OUTPUT_BINARY
    ls $OUTPUT_BINARY

    echo "[+] sending module map..."
    OUTPUT_HEADER_DIR=$BUILD_PREFIX/include

    pushd $OUTPUT_HEADER_DIR
    echo "module libAppleMobileDevice {" > module.modulemap
    for HEADER_FILE in $(find . -name "*.h"); do
        echo "    header \"$HEADER_FILE\"" >> module.modulemap
    done
    echo "    export *" >> module.modulemap
    echo "}" >> module.modulemap
    popd

    OUTPUT_BINARY_LIST+=($OUTPUT_BINARY)
    OUTPUT_HEADER_LIST+=($OUTPUT_HEADER_DIR)
}

TARGET_ARCHS=(
    arm64
    x86_64
)
for TARGET_ARCH in ${TARGET_ARCHS[@]}; do
    build_all $TARGET_ARCH
done

echo "[+] merging all archs..."
OUTPUT_BINARY=$WORKING_DIR/libimobiledevice.a
if [ -f $OUTPUT_BINARY ]; then
    rm -rf $OUTPUT_BINARY
fi
lipo -create ${OUTPUT_BINARY_LIST[@]} -output $OUTPUT_BINARY

echo "[+] making xcframework..."
if [ -d $OUTPUT_XCFRAMEWORK ]; then
    rm -rf $OUTPUT_XCFRAMEWORK
fi
COMMAND="xcodebuild -create-xcframework"
COMMAND="$COMMAND -library $OUTPUT_BINARY"
for ((i=0; i<${#OUTPUT_HEADER_LIST[@]}; i++)); do
    COMMAND="$COMMAND -headers ${OUTPUT_HEADER_LIST[$i]}"
done
$COMMAND -output $OUTPUT_XCFRAMEWORK

echo "[+] well done!"
