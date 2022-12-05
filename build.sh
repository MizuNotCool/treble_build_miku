#!/bin/bash
echo
echo "-----------------------------------------"
echo "      Miku UI TDA Treble Buildbot        "
echo "                  by                     "
echo "               xiaoleGun                 "
echo " Executing in 3 seconds - CTRL-C to exit "
echo "-----------------------------------------"
echo

sleep 3
set -e

BL=$(cd $(dirname $0);pwd)
BD=/tmp/itzkaguya/builds
VERSION="0.6.0"

initrepo() {
if [ ! -d .repo ]
then
    echo ""
    echo "--> Initializing Miku UI workspace"
    echo ""
    repo init -u https://github.com/Miku-UI/manifesto -b TDA --depth=1
fi

if [ -d .repo ] && [ ! -f .repo/local_manifests/miku-treble.xml ] ;then
     echo ""
     echo "--> Preparing local manifest"
     echo ""
     rm -rf .repo/local_manifests
     mkdir -p .repo/local_manifests
     echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<manifest>
  <remote name=\"github\"
          fetch=\"https://github.com\" />

  <project name=\"TrebleDroid/vendor_hardware_overlay\" path=\"vendor/hardware_overlay\" remote=\"github\" revision=\"pie\" />
  <project name=\"TrebleDroid/device_phh_treble\" path=\"device/phh/treble\" remote=\"github\" revision=\"android-13.0\" />
  <project name=\"phhusson/vendor_vndk-tests\" path=\"vendor/vndk-tests\" remote=\"github\" revision=\"master\" />
  <project name=\"phhusson/vendor_interfaces\" path=\"vendor/interfaces\" remote=\"github\" revision=\"android-11.0\" />
  <project name=\"phhusson/vendor_magisk\" path=\"vendor/magisk\" remote=\"github\" revision=\"android-10.0\" />
  <project name=\"phhusson/treble_app\" path=\"treble_app\" remote=\"github\" revision=\"master\" />
  <project name=\"phhusson/sas-creator\" path=\"sas-creator\" remote=\"github\" revision=\"master\" />
</manifest>" > .repo/local_manifests/miku-treble.xml
fi
}

syncrepo() {
echo ""
echo "--> Syncing repos"
echo ""
repo sync --no-repo-verify -c --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc --all)
}

applypatches() {
patches="$(readlink -f -- $1)"
tree="$2"

for project in $(cd $patches/patches/$tree; echo *);do
	p="$(tr _ / <<<$project |sed -e 's;platform/;;g')"
	[ "$p" == treble/app ] && p=treble_app
	[ "$p" == vendor/hardware/overlay ] && p=vendor/hardware_overlay
	pushd $p
	for patch in $patches/patches/$tree/$project/*.patch;do
		git am $patch || exit
	done
	popd
    done
}

applyingpatches() {
echo ""
echo "--> Applying TrebleDroid patches"
echo ""
applypatches $BL trebledroid
echo ""
echo "--> Applying Personal patches"
echo ""
applypatches $BL personal
}

initenvironment() {
echo ""
echo "--> Setting up build environment"
echo ""
source build/envsetup.sh &> /dev/null
mkdir -p $BD

echo ""
echo "--> Treble device generation"
echo ""
rm -rf device/*/sepolicy/common/private/genfs_contexts
cd device/phh/treble
git clean -fdx
bash generate.sh miku
cd ../../..
}

buildTrebleApp() {
    echo ""
    echo "--> Building treble_app"
    echo ""
    cd treble_app
    bash build.sh release
    cp TrebleApp.apk ../vendor/hardware_overlay/TrebleApp/app.apk
    cd ..
}

buildtreble() {
    echo ""
    echo "--> Building treble image"
    echo ""
    lunch miku_treble_a64_bvN-userdebug
    make installclean
    make -j$(nproc --all) systemimage
    mv $OUT/system.img $BD/system-miku_treble_a64_bvN.img
    sleep 1
}

buildSasImages() {
    echo ""
    echo "--> Building vndklite variant"
    echo ""
    cd sas-creator
    sudo bash lite-adapter.sh 64 $BD/system-miku_treble_arm64_bvN.img
    cp s.img $BD/system-miku_treble_arm64_bvN-vndklite.img
    sudo rm -rf s.img d tmp
    cd ..
}

generatePackages() {
    echo ""
    echo "--> Generating packages"
    echo ""
    BASE_IMAGE=$BD/system-miku_treble_a64_bvN.img
    mkdir --parents $BD/dsu/vanilla/; mv $BASE_IMAGE $BD/dsu/vanilla/system.img
    zip -j -v $BD/MikuUI-TDA-$VERSION-a64-ab-$BUILD_DATE-UNOFFICIAL.zip $BD/dsu/vanilla/system.img
    mkdir --parents $BD/dsu/vanilla-vndklite/; mv ${BASE_IMAGE%.img}-vndklite.img $BD/dsu/vanilla-vndklite/system.img
    zip -j -v $BD/MikuUI-TDA-$VERSION-a64-ab-vndklite-$BUILD_DATE-UNOFFICIAL.zip $BD/dsu/vanilla-vndklite/system.img
    rm -rf $BD/dsu
}

generateOtaJson() {
    echo ""
    echo "--> Generating Update json"
    echo ""
    prefix="MikuUI-TDA-$VERSION-"
    suffix="-$BUILD_DATE-UNOFFICIAL.zip"
    json="{\"version\": \"$VERSION\",\"date\": \"$(date +%s -d '-4hours')\",\"variants\": ["
    find $BD -name "*.zip" | {
        while read file; do
            packageVariant=$(echo $(basename $file) | sed -e s/^$prefix// -e s/$suffix$//)
            case $packageVariant in
                "a64-ab") name="miku_treble_a64_bvN";;
                "a64-ab-vndklite") name="miku_treble_a64_bvN-vndklite";;
            esac
            size=$(wc -c $file | awk '{print $1}')
            url="https://github.com/MizuNotCool/treble_build_miku/releases/download/TDA-$VERSION/$(basename $file)"
            json="${json} {\"name\": \"$name\",\"size\": \"$size\",\"url\": \"$url\"},"
        done
        json="${json%?}]}"
        echo "$json" | jq . > $BL/ota.json
        cp $BL/ota.json $BD/ota.json
    }
}

# I use a server so need it
personal() {
  echo ""
  echo "--> Pack all for me"
  echo ""
  7z a -t7z -r $BD/all.7z $BD/*-$BUILD_DATE-UNOFFICIAL.zip $BD/ota.json
  rm -rf $BD/*-$BUILD_DATE-UNOFFICIAL.zip $BD/ota.json
}

START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"

initrepo
syncrepo
applyingpatches
initenvironment
buildTrebleApp
buildtreble
buildSasImages
generatePackages
generateOtaJson
personal

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))

echo ""
echo "--> Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
