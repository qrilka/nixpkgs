{ lib
, stdenv
, chromium
, nodejs
, python3
, fetchYarnDeps
, fetchNpmDeps
, fixup_yarn_lock
, npmHooks
, yarn
, substituteAll
, libnotify
, unzip
, pkgs
, pkgsBuildHost

, info
}:

let
  fetchdep = dep: let
    opts = removeAttrs dep ["fetcher"];
  in pkgs.${dep.fetcher} opts;

  fetchedDeps = lib.mapAttrs (name: fetchdep) info.deps;

in (chromium.override { upstream-info = info.chromium; }).mkDerivation (base: {
  packageName = "electron";
  inherit (info) version;
  buildTargets = [ "electron:electron_dist_zip" ];

  nativeBuildInputs = base.nativeBuildInputs ++ [ nodejs yarn fixup_yarn_lock unzip npmHooks.npmConfigHook ];
  buildInputs = base.buildInputs ++ [ libnotify ];

  electronOfflineCache = fetchYarnDeps {
    yarnLock = fetchedDeps."src/electron" + "/yarn.lock";
    sha256 = info.electron_yarn_hash;
  };

  npmDeps = fetchNpmDeps rec {
    src = fetchedDeps."src";
    # Assume that the fetcher always unpack the source,
    # based on update.py
    sourceRoot = "${src.name}/third_party/node";
    hash = info.chromium_npm_hash;
  };

  src = null;

  patches = base.patches ++ lib.optional (lib.versionOlder info.version "27")
    (substituteAll {
      name = "version.patch";
      src = ./version.patch;
      inherit (info) version;
    }) ++ lib.optional (lib.versionAtLeast info.version "29")
    (substituteAll {
      # disable a component that requires CIPD blobs
      name = "disable-screen-ai.patch";
      src = ./disable-screen-ai.patch;
      inherit (info) version;
    })
  ;

  unpackPhase = ''
    runHook preUnpack
  '' + (
    lib.concatStrings (lib.mapAttrsToList (path: dep: ''
      mkdir -p ${builtins.dirOf path}
      cp -r ${dep}/. ${path}
      chmod u+w -R ${path}
    '') fetchedDeps)
  ) + ''
    sourceRoot=src
    runHook postUnpack
  '';

  npmRoot = "third_party/node";

  postPatch = ''
    mkdir -p third_party/jdk/current/bin

    echo 'build_with_chromium = true' >> build/config/gclient_args.gni
    echo 'checkout_google_benchmark = false' >> build/config/gclient_args.gni
    echo 'checkout_android = false' >> build/config/gclient_args.gni
    echo 'checkout_android_prebuilts_build_tools = false' >> build/config/gclient_args.gni
    echo 'checkout_android_native_support = false' >> build/config/gclient_args.gni
    echo 'checkout_ios_webkit = false' >> build/config/gclient_args.gni
    echo 'checkout_nacl = false' >> build/config/gclient_args.gni
    echo 'checkout_openxr = false' >> build/config/gclient_args.gni
    echo 'checkout_rts_model = false' >> build/config/gclient_args.gni
    echo 'checkout_src_internal = false' >> build/config/gclient_args.gni
    echo 'cros_boards = ""' >> build/config/gclient_args.gni
    echo 'cros_boards_with_qemu_images = ""' >> build/config/gclient_args.gni
    echo 'generate_location_tags = true' >> build/config/gclient_args.gni

    echo 'LASTCHANGE=${info.deps."src".rev}-refs/heads/master@{#0}'        > build/util/LASTCHANGE
    echo "$SOURCE_DATE_EPOCH"                                              > build/util/LASTCHANGE.committime

    cat << EOF > gpu/config/gpu_lists_version.h
    /* Generated by lastchange.py, do not edit.*/
    #ifndef GPU_CONFIG_GPU_LISTS_VERSION_H_
    #define GPU_CONFIG_GPU_LISTS_VERSION_H_
    #define GPU_LISTS_VERSION "${info.deps."src".rev}"
    #endif  // GPU_CONFIG_GPU_LISTS_VERSION_H_
    EOF

    cat << EOF > skia/ext/skia_commit_hash.h
    /* Generated by lastchange.py, do not edit.*/
    #ifndef SKIA_EXT_SKIA_COMMIT_HASH_H_
    #define SKIA_EXT_SKIA_COMMIT_HASH_H_
    #define SKIA_COMMIT_HASH "${info.deps."src/third_party/skia".rev}-"
    #endif  // SKIA_EXT_SKIA_COMMIT_HASH_H_
    EOF

    echo -n '${info.deps."src/third_party/dawn".rev}'                     > gpu/webgpu/DAWN_VERSION

    (
      cd electron
      export HOME=$TMPDIR/fake_home
      yarn config --offline set yarn-offline-mirror $electronOfflineCache
      fixup_yarn_lock yarn.lock
      yarn install --offline --frozen-lockfile --ignore-scripts --no-progress --non-interactive
    )

    (
      cd ..
      PATH=$PATH:${lib.makeBinPath (with pkgsBuildHost; [ jq git ])}
      config=src/electron/patches/config.json
      for entry in $(cat $config | jq -c ".[]")
      do
        patch_dir=$(echo $entry | jq -r ".patch_dir")
        repo=$(echo $entry | jq -r ".repo")
        for patch in $(cat $patch_dir/.patches)
        do
          echo applying in $repo: $patch
          git apply -p1 --directory=$repo --exclude='src/third_party/blink/web_tests/*' --exclude='src/content/test/data/*' $patch_dir/$patch
        done
      done
    )
  '' + base.postPatch;

  preConfigure = ''
    (
      cd third_party/node
      grep patch update_npm_deps | sh
    )
  '' + (base.preConfigure or "");

  gnFlags = rec {
    # build/args/release.gn
    is_component_build = false;
    is_official_build = true;
    rtc_use_h264 = proprietary_codecs;
    is_component_ffmpeg = true;

    # build/args/all.gn
    is_electron_build = true;
    root_extra_deps = [ "//electron" ];
    node_module_version = info.modules;
    v8_promise_internal_field_count = 1;
    v8_embedder_string = "-electron.0";
    v8_enable_snapshot_native_code_counters = false;
    v8_enable_javascript_promise_hooks = true;
    enable_cdm_host_verification = false;
    proprietary_codecs = true;
    ffmpeg_branding = "Chrome";
    enable_printing = true;
    angle_enable_vulkan_validation_layers = false;
    dawn_enable_vulkan_validation_layers = false;
    enable_pseudolocales = false;
    allow_runtime_configurable_key_storage = true;
    enable_cet_shadow_stack = false;
    is_cfi = false;
    use_qt = false;
    use_perfetto_client_library = false;
    enable_check_raw_ptr_fields = false;
  } // lib.optionalAttrs (lib.versionAtLeast info.version "27")  {
    v8_builtins_profiling_log_file = "";
    enable_dangling_raw_ptr_checks = false;
  } // lib.optionalAttrs (lib.versionAtLeast info.version "28") {
    dawn_use_built_dxc = false;
    v8_enable_private_mapping_fork_optimization = true;
  } // lib.optionalAttrs (lib.versionAtLeast info.version "29") {
    v8_expose_public_symbols = true;
  } // {

    # other
    enable_widevine = false;
    override_electron_version = info.version;
  };

  installPhase = ''
    mkdir -p $libExecPath
    unzip -d $libExecPath out/Release/dist.zip
  '';

  requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    inherit info fetchedDeps;
    headers = stdenv.mkDerivation rec {
      name = "node-v${info.node}-headers.tar.gz";
      nativeBuildInputs = [ python3 ];
      src = fetchedDeps."src/third_party/electron_node";
      buildPhase = ''
        make tar-headers
      '';
      installPhase = ''
        mv ${name} $out
      '';
    };
  };

  meta = with lib; {
    description = "Cross platform desktop application shell";
    homepage = "https://github.com/electron/electron";
    platforms = lib.platforms.linux;
    license = licenses.mit;
    maintainers = with maintainers; [ yuka ];
    mainProgram = "electron";
    hydraPlatforms = lib.optionals (!(hasInfix "alpha" info.version) && !(hasInfix "beta" info.version)) ["aarch64-linux" "x86_64-linux"];
    timeout = 172800; # 48 hours (increased from the Hydra default of 10h)
  };
})
