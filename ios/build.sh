#!/bin/sh
# Builds OpenJK single player for iOS -- Jedi Outcast (JK2 SP: OpenJO.app) or
# Jedi Academy (JA SP: OpenJA.app) -- then lays out the app.
#
#   ios/build.sh device [jo|ja]   # an iPhone / iPad (signed: see package-device.sh)
#   ios/build.sh sim [jo|ja]      # the iOS Simulator (ad-hoc signed)
#
# jo (Jedi Outcast) if no game is given.
#
# Everything is built next to this checkout, in its parent folder:
#   ../SDL2    SDL 2.30 (cloned if missing)
#   ../gl4es   gl4es with the iOS fixes (cloned from yoshisuga/gl4es if missing)
#   ../build/<device|sim>/   the builds, and OpenJO.app
set -e
SLICE=${1:-device}
GAME=${2:-jo}
case "$SLICE" in device|sim) ;; *) echo "usage: $0 device|sim [jo|ja]" >&2; exit 1 ;; esac
case "$GAME" in jo|ja) ;; *) echo "usage: $0 device|sim [jo|ja]" >&2; exit 1 ;; esac

OJK=$(cd "$(dirname "$0")/.." && pwd)
WS=$(dirname "$OJK")
TC=$OJK/ios/cmake/ios-$SLICE.cmake
B=$WS/build/$SLICE
P=$B/prefix
cd "$WS"

# A build folder set up with another toolchain file can't be reused: start
# it again
# (CMake keeps the one it was first set up with in CMakeSystem.cmake)
# -- and nor can one set up with an SDK that's gone (a newer Xcode replaced it)
fresh() {
	if [ -d "$1/CMakeFiles" ] && ! grep -qs "include(\"$TC\")" "$1"/CMakeFiles/*/CMakeSystem.cmake; then
		rm -rf "$1"
	fi
	SDK=$(grep -so '/Applications/[^;:]*\.sdk' "$1/CMakeCache.txt" | head -1)
	if [ -n "$SDK" ] && [ ! -d "$SDK" ]; then
		rm -rf "$1"
	fi
}
for d in SDL2 gl4es openjk openjk-ja; do fresh "$B/$d"; done
[ -f "$B/SDL2/CMakeCache.txt" ] || rm -rf "$P"

[ -d SDL2 ] || git clone --depth 1 -b release-2.30.x https://github.com/libsdl-org/SDL.git SDL2
[ -d gl4es ] || git clone https://github.com/yoshisuga/gl4es.git gl4es

# SDL2 with the UIScene lifecycle (ios/sdl2-uiscene.patch): iOS 27 stops apps
# built with its SDK that haven't adopted it. Applied once; SDL2 is built
# again whenever the patch changes (its hash is kept next to the build).
PATCH=$OJK/ios/sdl2-uiscene.patch
if git -C SDL2 apply --check "$PATCH" 2>/dev/null; then
	git -C SDL2 apply "$PATCH"
fi
PATCHSUM=$(shasum "$PATCH" | cut -d' ' -f1)
if [ "$(cat "$P/.sdl2-patch" 2>/dev/null)" != "$PATCHSUM" ]; then
	rm -rf "$P" "$B/SDL2"
fi

# SDL2, static
if [ ! -f "$P/lib/libSDL2.a" ]; then
	cmake -S SDL2 -B "$B/SDL2" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
		-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DCMAKE_INSTALL_PREFIX="$P"
	cmake --build "$B/SDL2"
	cmake --install "$B/SDL2"
	echo "$PATCHSUM" > "$P/.sdl2-patch"
fi

# gl4es (desktop GL 1.x on OpenGL ES 2), static, linked into the renderer only
cmake -S gl4es -B "$B/gl4es" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
	-DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$B/gl4es/lib"
cmake --build "$B/gl4es" --target GL

# OpenJK: one game's single player (engine, renderer, game library)
if [ "$GAME" = jo ]; then
	OUT=$B/openjk
	GAMEFLAGS="-DBuildSPEngine=OFF -DBuildSPGame=OFF -DBuildSPRdVanilla=OFF -DBuildJK2SPEngine=ON -DBuildJK2SPGame=ON -DBuildJK2SPRdVanilla=ON"
else
	OUT=$B/openjk-ja
	GAMEFLAGS="-DBuildSPEngine=ON -DBuildSPGame=ON -DBuildSPRdVanilla=ON -DBuildJK2SPEngine=OFF -DBuildJK2SPGame=OFF -DBuildJK2SPRdVanilla=OFF"
fi
cmake -S "$OJK" -B "$OUT" -G Ninja --toolchain "$TC" -DCMAKE_BUILD_TYPE=Release \
	-DBuildMPEngine=OFF -DBuildMPRdVanilla=OFF -DBuildMPDed=OFF -DBuildMPGame=OFF \
	-DBuildMPCGame=OFF -DBuildMPUI=OFF -DBuildMPRend2=OFF $GAMEFLAGS \
	-DUseInternalZlib=OFF -DUseInternalPNG=ON -DUseInternalJPEG=ON \
	-DUseInternalSDL2=OFF -DUseInternalOpenAL=OFF \
	-DCMAKE_PREFIX_PATH="$P" -DSDL2_DIR="$P/lib/cmake/SDL2" \
	-DGL4ES_DIR="$WS/gl4es" -DGL4ES_LIBRARY="$B/gl4es/lib/libGL.a"
cmake --build "$OUT"

"$OJK/ios/package-$SLICE.sh" "$GAME"
