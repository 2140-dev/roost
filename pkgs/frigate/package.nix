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
  version = "1.5.1";

  src = fetchFromGitHub {
    owner = "sparrowwallet";
    repo = "frigate";
    rev = "f8b0457f3b4bc7f80693bfe1bb203e3517270b5c"; # tag: 1.5.1
    hash = "sha256-0CwBrChpHrdmnvCTHHnRsqXu4pAHwev4DljpuYgo+W8=";
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

    # The nixpkgs nixDownloadDeps task resolves every resolvable
    # configuration, including `:compileClasspath`. That triggers the
    # extra-java-module-info transform, which wants to inspect the
    # drongo.jar produced by the `:drongo` subproject — but
    # nixDownloadDeps doesn't depend on that build, so the jar doesn't
    # exist yet and resolution fails. `skipLocalJars` does not cover the
    # case where the artifact comes from a project(:foo) dependency, so
    # we add an explicit task dependency to force drongo to build first.
    cat >> build.gradle <<'EOG'

    tasks.matching { it.name == 'nixDownloadDeps' && it.project == rootProject }.configureEach {
      dependsOn ':drongo:jar'
    }
    EOG
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
