{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  coreutils,
  xdg-utils,
  gtk3,
  glib,
  gdk-pixbuf,
  cairo,
  pango,
  atk,
  harfbuzz,
  libepoxy,
  libglvnd,
  libayatana-appindicator,
  libayatana-indicator,
  ayatana-ido,
  libdbusmenu,
  libdbusmenu-gtk3,
  keybinder3,
  libX11,
  libXcursor,
  libXrandr,
  libXinerama,
  libXi,
}:

let
  version = "0.4.2";
  # Include libraries loaded with dlopen, not only ELF DT_NEEDED entries.
  runtimeLibraries = [
    libepoxy
    libglvnd
    libayatana-appindicator
    libayatana-indicator
    ayatana-ido
    libdbusmenu
    libdbusmenu-gtk3
    keybinder3
  ];
in
stdenv.mkDerivation {
  pname = "flclashx";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pluralplay/FlClashX/releases/download/v${version}/FlClashX-linux-amd64.deb";
    hash = "sha256-whT1GPvJ/ZRoZtNSifX2y6BvHDswZyidYyrVo5rFGIA=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    wrapGAppsHook3
    makeWrapper
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    gtk3
    glib
    gdk-pixbuf
    cairo
    pango
    atk
    harfbuzz
    libX11
    libXcursor
    libXrandr
    libXinerama
    libXi
  ] ++ runtimeLibraries;
  runtimeDependencies = runtimeLibraries;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" unpacked
    runHook postUnpack
  '';
  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;
  # The real GUI must stay an ELF beside FlClashCore. Wrap only the launcher.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/flclashx" "$out/bin" "$out/libexec" "$out/share/applications"
    cp -a unpacked/opt/FlClashX/. "$out/share/flclashx/"
    chmod -R u+w,go-w "$out/share/flclashx"
    chmod 755 "$out/share/flclashx/FlClashX" "$out/share/flclashx/FlClashCore"

    install -Dm644 unpacked/usr/share/icons/hicolor/256x256/apps/FlClashX.png \
      "$out/share/icons/hicolor/256x256/apps/flclashx.png"
    cp unpacked/usr/share/applications/com.follow.clashx.desktop \
      "$out/share/applications/flclashx.desktop"
    sed -i \
      -e 's|^Exec=.*|Exec=flclashx|' \
      -e 's|^Icon=.*|Icon=flclashx|' \
      "$out/share/applications/flclashx.desktop"
    cat > "$out/libexec/flclashx-launch" <<'EOF'
    #!${stdenv.shell}
    cd /opt/FlClashX || exit 1
    exec /opt/FlClashX/FlClashX "$@"
    EOF
    chmod 755 "$out/libexec/flclashx-launch"
    runHook postInstall
  '';

  preFixup = ''
    addAutoPatchelfSearchPath "$out/share/flclashx/lib"
  '';
  postFixup = ''
    makeWrapper "$out/libexec/flclashx-launch" "$out/bin/flclashx" \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ coreutils xdg-utils ]} \
      --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibraries}"
    ln -s flclashx "$out/bin/FlClashX"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -x "$out/share/flclashx/FlClashX"
    test -x "$out/share/flclashx/FlClashCore"
    test ! -L "$out/share/flclashx/FlClashX"
    test ! -L "$out/share/flclashx/FlClashCore"
    test "$(head -c 4 "$out/share/flclashx/FlClashX")" = $'\x7fELF'
    test "$(head -c 4 "$out/share/flclashx/FlClashCore")" = $'\x7fELF'
    test -f "$out/share/flclashx/lib/libflutter_linux_gtk.so"
    test -f "$out/share/flclashx/lib/libapp.so"
    test -d "$out/share/flclashx/data/flutter_assets"
    test -f "$out/share/flclashx/data/icudtl.dat"
    grep -qx 'Exec=flclashx' "$out/share/applications/flclashx.desktop"
    grep -qx 'Icon=flclashx' "$out/share/applications/flclashx.desktop"
    runHook postInstallCheck
  '';

  meta = {
    description = "FlClashX binary bundle for a root-owned installation in /opt";
    homepage = "https://github.com/pluralplay/FlClashX";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "flclashx";
  };
}
