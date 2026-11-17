#!/usr/bin/env bash
# InstaDock fordítása PureDarwinra a puredarwin-vm eszközláncával (Zig, ld64, a VM image-éből
# kinyert PD SDK): PDVM=<a puredarwin-vm munkakönyvtára>, alapból ~/vm.
# Kimenet: build/Dock.app. A Kuka ikonjait a pd-downstream AppIcons rajzaiból készíti (PD_ICONS_REF, alapból
# feature/app-icons).
#
#   ./build.sh            fordítás
#   ./build.sh --install  fordítás, telepítés a VM-be a gyári Dock helyére, a Dock újraindítása
#   ./build.sh --restore  a gyári Dock visszaállítása a VM-ben, a Dock újraindítása
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PDVM="${PDVM:-$HOME/vm}"
source "$PDVM/build-scripts/env.sh"

target=/System/Library/CoreServices/Dock.app
backup=/System/Library/CoreServices/.Dock.app.original
# a Dock a munkamenet környezetével indul újra, mint a pd-wayland-session-ben
restart="for p in \$(ps ax -o pid,command | grep '[D]ock.app/Contents/MacOS/Dock' | awk '{print \$1}'); do kill \$p; done; sleep 1;
  ( XDG_RUNTIME_DIR=/var/run/user/0 WAYLAND_DISPLAY=wayland-0 ${ID_ENV:-} $target/Contents/MacOS/Dock >> /var/log/dock.log 2>&1 < /dev/null & ) ; sleep 2;
  ps ax | grep '[D]ock.app' ; tail -5 /var/log/dock.log"

if [ "${1:-}" = --restore ]; then
  "$V/vm-run.sh" "[ -d $backup ] || { echo 'nincs mentett gyári Dock'; exit 1; }
    rm -rf $target && mv $backup $target && echo 'a gyári Dock visszaállítva'; $restart" 60
  exit 0
fi

need "$SDK/usr/lib/libAppKit.dylib" "a puredarwin-vm-ben futtasd előbb az sdk.sh-t"
# az AppKit fejlécei a VM-be telepített AppKit forrásfájából (OUT=<az a build-kimenet>): az image-éi még
# CGWindowLevelKey-indexeket adnak szintnek (NSDesktopWindowLevel 2), az új AppKit valódi macOS-értékeket vár
need "$OUT/frameworks/include/AppKit/AppKit.h" "OUT=<a VM AppKitjének build-kimenete> kell (frameworks.sh AppKit)"
# egy régi fa fejlécei is megvannak (az alap ~/vm/build/out-éi ilyenek): azokkal az asztal 2-es szintű, közönséges
# ablak lesz, és minden más ablakot eltakar, amikor a Dock elé hozza (képernyőváltáskor, a munkamenet indulásakor)
grep -q 'NSDesktopWindowLevel = INT32_MIN' "$OUT/frameworks/include/AppKit/NSWindow.h" ||
  { echo "$OUT/frameworks/include AppKit-fejlécei még CGWindowLevelKey-indexeket adnak szintnek: OUT=<a VM-be telepített AppKit build-kimenete> kell" >&2; exit 1; }
o="$here/build"
app="$o/Dock.app/Contents"
rm -rf "$o"
mkdir -p "$o/obj" "$o/svg" "$app/MacOS" "$app/Resources"

cflags=("${CC_TARGET[@]}" -O2 -fno-omit-frame-pointer -D_DARWIN_C_SOURCE -fno-stack-protector "${FW_INC[@]}" "${SDK_INC[@]}"
        -F"$SDK/System/Library/Frameworks" -Wall -Wno-deprecated-declarations)
for src in "$here"/src/*.m; do
  "$ZIG" cc "${cflags[@]}" -x objective-c -fno-objc-arc -fobjc-exceptions -fblocks \
    -c "$src" -o "$o/obj/$(basename "$src" .m).o"
done
"$ZIG" cc "${cflags[@]}" -ffast-math -c "$here/src/IDGlass.c" -o "$o/obj/IDGlass.o"

# ugyanazok a könyvtárak, mint a PD saját AppKit-alkalmazásaiban
ld64 -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" "$o"/obj/*.o \
  -framework AppKit -framework QuartzCore -framework CoreText -framework CoreGraphics \
  -framework Onyx2D -lWindowServer -lFoundation -lCoreFoundation -lobjc -lSystem \
  -o "$app/MacOS/Dock"
python3 -I "$V/tools/check-imports.py" "$SDK" "$STAGE" "$app/MacOS/Dock"

cp "$here/Resources/Info.plist" "$app/Info.plist"
for l in "$here"/Resources/*.lproj; do
  mkdir -p "$app/Resources/$(basename "$l")"
  cp "$l"/*.strings "$app/Resources/$(basename "$l")/"
done

# a Kuka két ikonja a disztró saját rajzaiból (pd-downstream src/Userspace/AppIcons, jogvédett grafika), 256 px-en,
# hogy nagyítva is élesek legyenek; az alkalmazások és a mappák ikonja az NSWorkspace-től jön, mint a Finderben
need "$(command -v rsvg-convert)" "rsvg-convert kell (a nagy rajzok elmosása és vágása miatt), pl. nix shell nixpkgs#librsvg"
icons=(git -C "${PD_ICONS_GIT:-$PDVM/src/pd-downstream.git}" show)
icons_ref="${PD_ICONS_REF:-feature/app-icons}"
for name in trash trash-full; do
  "${icons[@]}" "$icons_ref:src/Userspace/AppIcons/Resources/$name.svg" > "$o/svg/$name.svg"
  rsvg-convert -w 256 -h 256 "$o/svg/$name.svg" -o "$app/Resources/$name.png"
done
echo "kész: $o/Dock.app"

if [ "${1:-}" = --install ]; then
  tarball="$(mktemp)"
  tar -C "$o" --owner=0 --group=0 -cf "$tarball" Dock.app
  "$V/tools/vm-put.sh" "$tarball" /tmp/instadock.tar 644
  rm -f "$tarball"
  # az első telepítés elteszi a gyári Dockot, a többi csak cserél
  "$V/vm-run.sh" "set -e; [ -d $backup ] || cp -Rp $target $backup; rm -rf /tmp/instadock && mkdir /tmp/instadock &&
    tar -C /tmp/instadock -xf /tmp/instadock.tar && rm -rf $target && mv /tmp/instadock/Dock.app $target &&
    rm -rf /tmp/instadock /tmp/instadock.tar && echo 'InstaDock telepítve'; set +e; $restart" 90
fi
