#!/bin/sh
# Builds Jedi Outcast single player (OpenJK's JK2 SP: engine, renderer, game)
# for iOS, then lays out OpenJO.app.
#
#   ios/build.sh device     # an iPhone / iPad (signed: see package-device.sh)
#   ios/build.sh sim        # the iOS Simulator (ad-hoc signed)
#
# Everything is built next to this checkout, in its parent folder:
#   ../SDL2    SDL 2.30 (cloned if missing)
#   ../gl4es   gl4es with the iOS fixes (cloned from yoshisuga/gl4es if missing)
#   ../build/<device|sim>/   the builds, and OpenJO.app
set -e
SLICE=${1:-device}
case "$SLICE" in device|sim) ;; *) echo "usage: $0 device|sim" >&2; exit 1 ;; esac

OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
TC=$OJK/ios/cmake/ios-$SLICE.cmake
B=$WS/build/$SLICE
P=$B/prefix
cd "$WS"

[ -d SDL2 ] || git clone --depth 1 -b release-2.30.x https://github.com/libsdl-org/SDL.git SDL2
[ -d gl4es ] || git clone https://github.com/yoshisuga/gl4es.git gl4es

# SDL2, static
if [ ! -f "$P/lib/libSDL2.a" ]; then
	cmake -S SDL2 -B "$B/SDL2" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
		-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DCMAKE_INSTALL_PREFIX="$P"
	cmake --build "$B/SDL2"
	cmake --install "$B/SDL2"
fi

# gl4es (desktop GL 1.x on OpenGL ES 2), static, linked into the renderer only
cmake -S gl4es -B "$B/gl4es" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
	-DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$B/gl4es/lib"
cmake --build "$B/gl4es" --target GL

# OpenJK: Jedi Outcast single player only
cmake -S "$OJK" -B "$B/openjk" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
	-DBuildMPEngine=OFF -DBuildMPRdVanilla=OFF -DBuildMPDed=OFF -DBuildMPGame=OFF \
	-DBuildMPCGame=OFF -DBuildMPUI=OFF -DBuildMPRend2=OFF \
	-DBuildSPEngine=OFF -DBuildSPGame=OFF -DBuildSPRdVanilla=OFF \
	-DBuildJK2SPEngine=ON -DBuildJK2SPGame=ON -DBuildJK2SPRdVanilla=ON \
	-DUseInternalZlib=OFF -DUseInternalPNG=ON -DUseInternalJPEG=ON \
	-DUseInternalSDL2=OFF -DUseInternalOpenAL=OFF \
	-DCMAKE_PREFIX_PATH="$P" -DSDL2_DIR="$P/lib/cmake/SDL2" \
	-DGL4ES_DIR="$WS/gl4es" -DGL4ES_LIBRARY="$B/gl4es/lib/libGL.a"
cmake --build "$B/openjk"

"$OJK/ios/package-$SLICE.sh"
