{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle_9,
  jdk25,
  makeBinaryWrapper,
}:

let
  drongoSrc = fetchFromGitHub {
    owner = "sparrowwallet";
    repo = "drongo";
    rev = "dad9fe2fccda624566e44324d0da42a3423f8e6e";
    hash = "sha256-SOVoSH2E8VexgSN/WQ+kF0m6NJ3thnr+j34ZTeU1t+4=";
  };

  frigateGradle = gradle_9.override { java = jdk25; };

  nativePlatform = if stdenv.hostPlatform.isDarwin then "macos" else "linux";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "frigate";
  version = "1.4.1";

  src = fetchFromGitHub {
    owner = "sparrowwallet";
    repo = "frigate";
    rev = "0d4f5159531ed6f6d0a2364605eba2bec3766aff";
    hash = "sha256-dHKQTepvmj7YSIIDBKL09tF+Fotk/O45fUD6sFS7zmA=";
  };

  postUnpack = ''
    rm -rf "$sourceRoot/drongo"
    cp -r --no-preserve=mode,ownership ${drongoSrc} "$sourceRoot/drongo"
  '';

  postPatch = ''
    for d in linux macos windows; do
      [ "$d" = "${nativePlatform}" ] || rm -rf "src/main/resources/native/$d"
    done

    # Drop --strip-native-commands so the jlink image keeps bin/java; the
    # beryx launcher script invokes "$DIR/java" relative to itself.
    substituteInPlace build.gradle \
      --replace-fail "'--strip-native-commands', " ""

    # Drop the addUserWritePermission task: it runs `chmod -R u+w` on the
    # jlink image's legal/ directory, which fails inside the Linux Nix
    # sandbox (the legal files trace back to a read-only /nix/store path).
    # The task is only useful for the jpackage deb/rpm flow, which we don't
    # run — the jlink output is what we install.
    substituteInPlace build.gradle \
      --replace-fail "tasks.jlink.finalizedBy('addUserWritePermission')" ""
  '';

  nativeBuildInputs = [
    frigateGradle
    jdk25
    makeBinaryWrapper
  ];

  mitmCache = frigateGradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = ./deps.json;
  };

  gradleFlags = [
    "--no-daemon"
    "-Dorg.gradle.java.installations.auto-download=false"
  ];

  gradleBuildTask = "jlink";

  doCheck = false;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/frigate"
    cp -r build/image/. "$out/share/frigate/"

    mkdir -p "$out/bin"
    for launcher in frigate frigate-cli; do
      makeBinaryWrapper "$out/share/frigate/bin/$launcher" "$out/bin/$launcher"
    done

    runHook postInstall
  '';

  meta = {
    description = "Silent payments scanning server for Bitcoin, by Sparrow Wallet";
    homepage = "https://github.com/sparrowwallet/frigate";
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    mainProgram = "frigate";
  };
})
