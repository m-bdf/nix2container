{ pkgs ? import <nixpkgs> {} }:

let
  l = pkgs.lib // builtins;

  nix2container-bin = pkgs.buildGoModule {
    pname = "nix2container";
    version = "1.0.0";
    src = l.cleanSourceWith {
      src = ./.;
      filter = path: type:
      let
        p = baseNameOf path;
      in !(
        p == "flake.nix" ||
        p == "flake.lock" ||
        p == "examples" ||
        p == "tests" ||
        p == "README.md" ||
        p == "default.nix"
      );
    };
    vendorHash = "sha256-/j4ZHOwU5Xi8CE/fHha+2iZhsLd/y2ovzVhvg8HDV78=";
    ldflags = l.optional pkgs.stdenv.isDarwin
      "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true";
  };

  skopeo-nix2container = pkgs.skopeo.overrideAttrs (old: {
    EXTRA_LDFLAGS = l.optionalString pkgs.stdenv.isDarwin "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true";
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.patchutils ];
    preBuild = let
      # Needs to use fetchpatch2 to handle "git extended headers", which include
      # lines with semantic content like "rename from" and "rename to".
      # However, it also includes "index" lines which include the git revision(s) the patch was initially created from.
      # These lines may include revisions of differing length, based on how Github generates them.
      # fetchpatch2 does not filter out, but probably should
      fetchgitpatch = args: pkgs.fetchpatch2 (args // {
        postFetch = (args.postFetch or "") + ''
          sed -i \
            -e '/^index /d' \
            -e '/^similarity index /d' \
            -e '/^dissimilarity index /d' \
            $out
        '';
      });
      patch = fetchgitpatch {
        url = "https://github.com/nlewo/image/commit/c2254c998433cf02af60bf0292042bd80b96a77e.patch";
        sha256 = "sha256-6CUjz46xD3ORgwrHwdIlSu6JUj7WLS6BOSyRGNnALHY=";
      };
    in ''
      mkdir -p vendor/github.com/nlewo/nix2container/
      cp -r ${nix2container-bin.src}/* vendor/github.com/nlewo/nix2container/
      cd vendor/github.com/containers/image/v5
      mkdir nix/
      touch nix/transport.go
      # The patch for alltransports.go does not apply cleanly to skopeo > 1.14,
      # filter the patch and insert the import manually here instead.
      filterdiff -x '*/alltransports.go' ${patch} | patch -p1
      sed -i '\#_ "github.com/containers/image/v5/tarball"#a _ "github.com/containers/image/v5/nix"' transports/alltransports/alltransports.go
      cd -

      # Go checks packages in the vendor directory are declared in the modules.txt file.
      echo '# github.com/nlewo/nix2container v1.0.0' >> vendor/modules.txt
      echo '## explicit; go 1.13' >> vendor/modules.txt
      echo github.com/nlewo/nix2container/nix >> vendor/modules.txt
      echo github.com/nlewo/nix2container/types >> vendor/modules.txt
      echo github.com/containers/image/v5/nix >> vendor/modules.txt
      # All packages declared in the modules.txt file must also be required by the go.mod file.
      echo 'require (' >> go.mod
      echo '  github.com/nlewo/nix2container v1.0.0' >> go.mod
      echo ')' >> go.mod
    '';
  });

  writeSkopeoApplication = name: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = [ pkgs.jq skopeo-nix2container ];
    excludeShellChecks = [ "SC2068" ];
  };

  copyToDockerDaemon = image: writeSkopeoApplication "copy-to-docker-daemon" ''
    echo "Copy to Docker daemon image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} docker-daemon:${image.imageName}:${image.imageTag} "$@"
  '';

  copyToRegistry = image: writeSkopeoApplication "copy-to-registry" ''
    echo "Copy to Docker registry image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} docker://${image.imageName}:${image.imageTag} "$@"
  '';

  copyToPodman = image: writeSkopeoApplication "copy-to-podman" ''
    echo "Copy to podman image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} containers-storage:${image.imageName}:${image.imageTag} "$@"
  '';

  copyTo = image: writeSkopeoApplication "copy-to" ''
    echo "Running skopeo --insecure-policy copy nix:${image}" "$@"
    skopeo --insecure-policy copy nix:${image} "$@"
  '';

  # Pull an image from a registry with Skopeo and translate it to a
  # nix2container image.json file.
  # This mainly comes from nixpkgs/build-support/docker/default.nix.
  #
  # Credentials:
  # If you use the nix daemon for building, here is how you set up creds:
  # docker login URL to whatever it is
  # copy ~/.docker/config.json to /etc/nix/skopeo/auth.json
  # Make the directory and all the files readable to the nixbld group
  # sudo chmod -R g+rx /etc/nix/skopeo
  # sudo chgrp -R nixbld /etc/nix/skopeo
  # Now, bind mount the file into the nix build sandbox
  # extra-sandbox-paths = /etc/skopeo/auth.json=/etc/nix/skopeo/auth.json
  # update /etc/nix/skopeo/auth.json every time you add a new registry auth
  pullImage =
    let
      fixName = name: l.replaceStrings [ "/" ":" ] [ "-" "-" ] name;
    in
    { imageName
      # To find the digest of an image, you can use skopeo:
      # see doc/functions.xml
    , imageDigest
    , sha256
    , os ? "linux"
    , arch ? pkgs.go.GOARCH
    , tlsVerify ? true
    , name ? fixName "docker-image-${imageName}"
    }: let
      sourceURL = "docker://${imageName}@${imageDigest}";
      authFile = "/etc/skopeo/auth.json";
      dir = pkgs.runCommand name
      {
        inherit imageDigest;
        impureEnvVars = l.fetchers.proxyImpureEnvVars;
        nativeBuildInputs = with pkgs; [ cacert skopeo ];

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = sha256;
      } ''
        if [ -f "${authFile}" ]; then
          authFlag="--authfile ${authFile}"
        fi

        skopeo copy "${sourceURL}" "dir://$out" \
          --insecure-policy \
          --tmpdir=$TMPDIR \
          --override-os ${os} \
          --override-arch ${arch} \
          --src-tls-verify=${l.boolToString tlsVerify} \
          $authFlag
      '';
    in pkgs.runCommand "nix2container-${imageName}.json" {} ''
      ${nix2container-bin}/bin/nix2container image-from-dir $out ${dir}
    '';

  pullImageFromManifest =
    { imageName
    , imageManifest ? null
    # The manifest dictates what is pulled; these three are only used for
    # the supplied manifest-pulling script.
    , imageTag ? "latest"
    , os ? "linux"
    , arch ? pkgs.go.GOARCH
    , tlsVerify ? true
    , registryUrl ? "registry-1.docker.io"
    }: let
      manifest = l.importJSON imageManifest;

      buildImageBlob = digest:
        let
          blobUrl = "https://${registryUrl}/v2/${imageName}/blobs/${digest}";
          plainDigest = l.removePrefix "sha256:" digest;
          insecureFlag = l.optionalString (!tlsVerify) "--insecure";
        in pkgs.runCommand plainDigest {
          impureEnvVars = l.fetchers.proxyImpureEnvVars;
          nativeBuildInputs = with pkgs; [ cacert curl jq ];
          outputHash = digest;
        } ''
          # This initial access is expected to fail as we don't have a token.
          tokenUrl="$(
            curl --location ${insecureFlag} --head --silent "${blobUrl}" \
              --output /dev/null --write-out '%header{www-authenticate}' |
            sed -E 's/Bearer realm="([^"]+)",(.*)/\1?\2/; s/,/\&/g; s/"//g'
          )"

          if [ -n "$tokenUrl" ]; then
            echo "Token URL: $tokenUrl"
            authFlag="--oauth2-bearer $(
              curl --location ${insecureFlag} --fail --silent "$tokenUrl" |
              jq --raw-output .token
            )"
          else
            echo "No token URL found, trying without authentication"
          fi

          echo "Blob URL: ${blobUrl}"
          curl --location ${insecureFlag} --fail $authFlag "${blobUrl}" --output $out
        '';

      # Pull the blobs (archives) for all layers, as well as the one for the image's config JSON.
      layerBlobs = map (layerManifest: buildImageBlob layerManifest.digest) manifest.layers;
      configBlob = buildImageBlob manifest.config.digest;

      # Write the blob map out to a JSON file for the GO executable to consume.
      blobMap = l.listToAttrs (map (drv: { name = drv.name; value = drv; }) (layerBlobs ++ [configBlob]));
      blobMapFile = pkgs.writeText "${imageName}-blobs.json" (l.toJSON blobMap);

      # Convenience scripts for manifest-updating.
      filter = ''.manifests[] | select((.platform.os=="${os}") and (.platform.architecture=="${arch}")) | .digest'';
      getManifest = writeSkopeoApplication "get-manifest" ''
        set -e
        manifest=$(skopeo inspect docker://${registryUrl}/${imageName}:${imageTag} --raw)
        if echo "$manifest" | jq -e .manifests >/dev/null; then
          # Multi-arch image, pick the one that matches the supplied platform details.
          hash=$(echo "$manifest" | jq -r '${filter}')
          skopeo inspect "docker://${registryUrl}/${imageName}@$hash" --raw
        else
          # Single-arch image, return the initial response.
          echo -n "$manifest"
        fi
      '';

    in pkgs.runCommand "nix2container-${imageName}.json" {
      passthru = { inherit getManifest; };
    } ''
      ${nix2container-bin}/bin/nix2container image-from-manifest $out ${imageManifest} ${blobMapFile}
    '';

  buildLayer = {
    # A list of store paths to include in the layer.
    deps ? [],
    # A derivation (or list of derivations) to include in the layer
    # root directory. The store path prefix /nix/store/hash-path is
    # removed. The store path content is then located at the layer /.
    copyToRoot ? null,
    # A store path to ignore. This is mainly useful to ignore the
    # configuration file from the container layer.
    ignore ? null,
    # A list of layers built with the buildLayer function: if a store
    # path in deps or copyToRoot belongs to one of these layers, this
    # store path is skipped. This is pretty useful to
    # isolate store paths that are often updated from more stable
    # store paths, to speed up build and push time.
    layers ? [],
    # Store the layer tar in the derivation. This is useful when the
    # layer dependencies are not bit reproducible.
    reproducible ? true,
    # A list of file permisssions which are set when the tar layer is
    # created: these permissions are not written to the Nix store.
    #
    # Each element of this permission list is a dict such as
    # { path = "a store path";
    #   regex = ".*";
    #   mode = "0664";
    # }
    # The mode is applied on a specific path. In this path subtree,
    # the mode is then applied on all files matching the regex.
    perms ? [],
    # The maximun number of layer to create. This is based on the
    # store path "popularity" as described in
    # https://grahamc.com/blog/nix-and-layered-docker-images
    maxLayers ? 1,
    # Deprecated: will be removed on v1
    contents ? null,
    # Author, comment, created_by
    metadata ? { created_by = "nix2container"; },
  }: let
    subcommand = if reproducible
      then "layers-from-reproducible-storepaths"
      else "layers-from-non-reproducible-storepaths";

    copyToRootList =
      let derivations = if contents == null then copyToRoot else contents;
      in if derivations == null then [] else l.toList derivations;

    # This is to move all storepaths in the copyToRoot attribute to the
    # image root.
    rewrites = map (p: {
	    path = p;
	    regex = "^${p}";
	    repl = "";
    }) copyToRootList;

    rewritesFile = pkgs.writeText "rewrites.json" (l.toJSON rewrites);
    rewritesFlag = "--rewrites ${rewritesFile}";

    permsFile = pkgs.writeText "perms.json" (l.toJSON perms);
    permsFlag = l.optionalString (perms != []) "--perms ${permsFile}";

    historyFile = pkgs.writeText "history.json" (l.toJSON metadata);
    historyFlag = l.optionalString (metadata != {}) "--history ${historyFile}";

    allDeps = deps ++ copyToRootList;
    tarDirectory = l.optionalString (!reproducible) "--tar-directory $out";

    layersJSON = pkgs.runCommand "layers.json" {} ''
      mkdir $out
      ${nix2container-bin}/bin/nix2container ${subcommand} \
        $out/layers.json \
        ${closureGraph allDeps ignore} \
        --max-layers ${toString maxLayers} \
        ${rewritesFlag} \
        ${permsFlag} \
        ${historyFlag} \
        ${tarDirectory} \
        ${l.concatMapStringsSep " "  (l: l + "/layers.json") layers} \
    '';
  in checked { inherit copyToRoot contents; } layersJSON;

  # Create a nix database from all paths contained in the given closureGraphJson.
  # Also makes all these paths store roots to prevent them from being garbage collected.
  makeNixDatabase = closureGraphJson:
    assert l.isDerivation closureGraphJson;
    pkgs.runCommand "nix-database" {
      nativeBuildInputs = with pkgs; [ jq nix sqlite ];
    } ''
      echo "Generating the nix database from ${closureGraphJson}..."

      # Avoid including the closureGraph derivation itself.
      # Transformation taken from https://github.com/NixOS/nixpkgs/blob/c22ce64ccddc6d59cb3747827d0417f8c10bd9cf/pkgs/build-support/closure-info.nix#L70
      jq -r 'map([.path, .narHash, .narSize, "", (.references | length)] + .references) | add | map("\(.)\n") | add' ${closureGraphJson} |
        head -n -1 |
        NIX_REMOTE="local?root=$PWD" nix-store --load-db -j 1

      # Sanitize time stamps
      sqlite3 $PWD/nix/var/nix/db/db.sqlite 'UPDATE ValidPaths SET registrationTime = 0;'

      # Dump and reimport to ensure that the update order doesn't somehow change the DB.
      sqlite3 $PWD/nix/var/nix/db/db.sqlite '.dump' > db.dump
      mkdir -p $out/nix/var/nix/db/
      sqlite3 $out/nix/var/nix/db/db.sqlite '.read db.dump'

      mkdir -p $out/nix/var/nix/gcroots/docker/
      for i in $(jq -r 'map("\(.path)\n") | add' ${closureGraphJson}); do
        ln -s $i $out/nix/var/nix/gcroots/docker/$(basename $i)
      done
    '';

  # Write the references of `path' to a file but do not include `ignore' itself if non-null.
  closureGraph = paths: ignore:
    let ignoreList = if ignore == null then [] else l.toList ignore;
    in pkgs.runCommand "closure-graph.json" {
      exportReferencesGraph.graph = paths;
      __structuredAttrs = true;

      ignoreListJson = l.toJSON (map toString ignoreList);
      outputChecks.out.disallowedReferences = ignoreList;

      nativeBuildInputs = [ pkgs.jq ];
    } ''
      jq '.graph | map(select(.path as $p | $ignore | index($p) | not)) | map(.references |= sort_by(.)) | sort_by(.path)' \
        --argjson ignore "$ignoreListJson" .attrs.json > $out
    '';

  buildImage = {
    name,
    # Image tag, when null then the nix output hash will be used.
    tag ? null,
    # An attribute set describing an image configuration as defined in
    # https://github.com/opencontainers/image-spec/blob/8b9d41f48198a7d6d0a5c1a12dc2d1f7f47fc97f/specs-go/v1/config.go#L23
    config ? {},
    # A list of layers built with the buildLayer function: if a store
    # path in deps or copyToRoot belongs to one of these layers, this
    # store path is skipped. This is pretty useful to
    # isolate store paths that are often updated from more stable
    # store paths, to speed up build and push time.
    layers ? [],
    # A derivation (or list of derivation) to include in the layer
    # root. The store path prefix /nix/store/hash-path is removed. The
    # store path content is then located at the image /.
    copyToRoot ? null,
    # An image that is used as base image of this image.
    fromImage ? "",
    # Image architecture
    arch ? pkgs.go.GOARCH,
    # A list of file permisssions which are set when the tar layer is
    # created: these permissions are not written to the Nix store.
    #
    # Each element of this permission list is a dict such as
    # { path = "a store path";
    #   regex = ".*";
    #   mode = "0664";
    # }
    # The mode is applied on a specific path. In this path subtree,
    # the mode is then applied on all files matching the regex.
    perms ? [],
    # The maximun number of layer to create. This is based on the
    # store path "popularity" as described in
    # https://grahamc.com/blog/nix-and-layered-docker-images
    # Note this is applied on the image layers and not on layers added
    # with the buildImage.layers attribute
    maxLayers ? 1,
    # If set to true, the Nix database is initialized with all store
    # paths added into the image. Note this is only useful to run nix
    # commands from the image, for instance to build an image used by
    # a CI to run Nix builds.
    initializeNixDatabase ? false,
    # If initializeNixDatabase is set to true, the uid/gid of /nix can be
    # controlled using nixUid/nixGid.
    nixUid ? 0,
    nixGid ? 0,
    # Time of creation of the image.
    created ? "0001-01-01T00:00:00Z",
    # Deprecated: will be removed
    contents ? null,
    meta ? {},
  }:
    let
      configFile = pkgs.writeText "config.json" (l.toJSON config);
      copyToRootList =
        let derivations = if contents == null then copyToRoot else contents;
        in if derivations == null then [] else l.toList derivations;

      # Expand the given list of layers to include all their transitive layer dependencies.
      layersWithNested = layers:
        let layerWithNested = layer: [layer] ++ (l.concatMap layerWithNested (layer.layers or []));
        in l.concatMap layerWithNested layers;
      explodedLayers = layersWithNested layers;
      ignore = [configFile] ++ explodedLayers;

      closureGraphForAllLayers = closureGraph ([configFile] ++ copyToRootList ++ layers) ignore;
      nixDatabase = makeNixDatabase closureGraphForAllLayers;
      # This layer contains all config dependencies. We ignore the
      # configFile because it is already part of the image, as a
      # specific blob.

      perms' = perms ++ l.optional initializeNixDatabase
        {
          path = nixDatabase;
          regex = ".*";
          mode = "0755";
          uid = nixUid;
          gid = nixGid;
        };

      customizationLayer = buildLayer {
        inherit maxLayers;
        perms = perms';
        copyToRoot = copyToRootList ++ l.optional initializeNixDatabase nixDatabase;
        deps = [configFile];
        ignore = configFile;
        layers = layers;
      };

      fromImageFlag = l.optionalString (fromImage != "") "--from-image ${fromImage}";
      archFlag = "--arch ${arch}";
      createdFlag = "--created ${created}";
      layerPaths = l.concatMapStringsSep " " (l: l + "/layers.json") (layers ++ [customizationLayer]);

      imageName = l.toLower name;
      imageTag =
        let hash = l.head (l.splitString "-" (baseNameOf image.outPath));
        in if tag == null then hash else tag;

      image = pkgs.runCommand "image-${baseNameOf name}.json" {
        allowSubstitutes = false;

        inherit meta;
        passthru = {
          inherit fromImage imageName imageTag;
          # provide a cheap to evaluate image reference for use with external tools like docker
          # DO NOT use as an input to other derivations, as there is no guarantee that the image
          # reference will exist in the store.
          imageRefUnsafe = l.unsafeDiscardStringContext "${imageName}:${imageTag}";

          copyToDockerDaemon = copyToDockerDaemon image;
          copyToRegistry = copyToRegistry image;
          copyToPodman = copyToPodman image;
          copyTo = copyTo image;
        };
      } ''
        ${nix2container-bin}/bin/nix2container image \
        $out \
        ${fromImageFlag} \
        ${archFlag} \
        ${createdFlag} \
        ${configFile} \
        ${layerPaths}
      '';
    in checked { inherit copyToRoot contents; } image;

    checked = { copyToRoot, contents }:
      l.warnIf (contents != null)
        "The contents parameter is deprecated. Change to copyToRoot if the contents are designed to be copied to the root filesystem, such as when you use `buildEnv` or similar between contents and your packages. Use copyToRoot = buildEnv { ... }; or similar if you intend to add packages to /bin."
      l.throwIf (contents != null && copyToRoot != null)
        "You can not specify both contents and copyToRoot."
      ;
in
{
  inherit nix2container-bin skopeo-nix2container;
  nix2container = { inherit buildImage buildLayer pullImage pullImageFromManifest; };
}
