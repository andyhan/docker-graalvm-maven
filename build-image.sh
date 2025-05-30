#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-graalvm-maven
#

shared_lib="$(dirname $0)/.shared"
[ -e "$shared_lib" ] || curl -sSf https://raw.githubusercontent.com/vegardit/docker-shared/v1/download.sh?_=$(date +%s) | bash -s v1 "$shared_lib" || exit 1
source "$shared_lib/lib/build-image-init.sh"


#################################################
# specify target docker registry/repo
#################################################
graalvm_version=${GRAALVM_VERSION:-latest}
java_major_version=${GRAALVM_JAVA_VERSION:-11}
docker_registry=${DOCKER_REGISTRY:-docker.io}
image_repo=${DOCKER_IMAGE_REPO:-vegardit/graalvm-maven}
image_tag="${DOCKER_IMAGE_TAG:-$graalvm_version-java$java_major_version}" # e.g. dev-java17, latest-java17, 22.3.2-java17


#################################################
# determine GraalVM download URL
#################################################
case $graalvm_version in
   dev)   graalvm_version=$(curl -fsSL -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/graalvm/graalvm-ce-dev-builds/releases/latest | grep "tag_name" | cut -d'"' -f4)
          # {{ARCH}}, {{ARCH_1}}, {{ARCH_2}}, ..: Placeholders for architecture (e.g., x86_64, aarch64).
          # get_arch_name in Dockerfile determines the correct architecture (amd64/arm64).
          graalvm_url="https://github.com/graalvm/graalvm-ce-dev-builds/releases/download/${graalvm_version}/graalvm-community-java${java_major_version}-linux-{{ARCH_3}}-dev.tar.gz"
          ;;

   *dev*) graalvm_url="https://github.com/graalvm/graalvm-ce-dev-builds/releases/download/${graalvm_version}/graalvm-community-java${java_major_version}-linux-{{ARCH_3}}-dev.tar.gz"
          ;;

   latest) case $java_major_version in
              11) graalvm_version="22.3.3";
                  graalvm_url="https://github.com/graalvm/graalvm-ce-builds/releases/download/vm-${graalvm_version}/graalvm-ce-java11-linux-{{ARCH_3}}-${graalvm_version}.tar.gz"
                  ;;
              *)  graalvm_version=$(curl -sSfL -N -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/graalvm/graalvm-ce-builds/git/matching-refs/tags/jdk-${java_major_version} | jq -r 'last | .ref | split("-")[-1]')
                  graalvm_url="https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${graalvm_version}/graalvm-community-jdk-${graalvm_version}_linux-{{ARCH_2}}_bin.tar.gz"
                  ;;
           esac
           ;;

   *)      graalvm_url="https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${graalvm_version}/graalvm-community-jdk-${graalvm_version}_linux-{{ARCH_2}}_bin.tar.gz"
           image_tag="${DOCKER_IMAGE_TAG:-$graalvm_version}" # e.g. 17.0.7
           ;;
esac
echo "Effective GRAALVM_VERSION: $graalvm_version"

image_name=$image_repo:$image_tag


#################################################
# build the image
#################################################
echo "Building docker image [$image_name]..."
if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
   project_root=$(cygpath -w "$project_root")
fi

export DOCKER_BUILDKIT=1
docker run -d -p 5000:5000 --name registry registry
local_registery=localhost:5000
trap 'docker rm $(docker stop $(docker ps -a --filter ancestor=registry --format="{{.ID}}"))' EXIT
docker buildx create --name multiarchbuilder --driver docker-container --driver-opt network=host --bootstrap --platform linux/amd64,linux/arm64
trap 'docker buildx rm multiarchbuilder' EXIT
docker buildx build "$project_root" \
   --file "image/Dockerfile" \
   --progress=plain \
   --pull \
   --builder multiarchbuilder \
   --platform linux/amd64,linux/arm64 \
   --push \
   `# using the current date as value for BASE_LAYER_CACHE_KEY, i.e. the base layer cache (that holds system packages with security updates) will be invalidate once per day` \
   --build-arg BASE_LAYER_CACHE_KEY=$base_layer_cache_key \
   --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
   --build-arg GRAALVM_DOWNLOAD_URL="$graalvm_url" \
   --build-arg JAVA_MAJOR_VERSION="$java_major_version" \
   --build-arg UPX_COMPRESS="${UPX_COMPRESS:-true}" \
   --build-arg GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}" \
   --build-arg GIT_COMMIT_DATE="$(date -d @$(git log -1 --format='%at') --utc +'%Y-%m-%d %H:%M:%S UTC')" \
   --build-arg GIT_COMMIT_HASH="$(git rev-parse --short HEAD)" \
   --build-arg GIT_REPO_URL="$(git config --get remote.origin.url)" \
   --build-arg GITHUB_TOKEN="$GITHUB_TOKEN" \
   -t $local_registery/$image_name \
   "$@"


#################################################
# pull the container image and retag for security audit and following tasks
#################################################
docker pull $local_registery/$image_name
docker tag $local_registery/$image_name $image_name


#################################################
# perform security audit
#################################################
if [[ "${DOCKER_AUDIT_IMAGE:-1}" == 1 ]]; then
   bash "$shared_lib/cmd/audit-image.sh" $image_name
fi


#################################################
# runs crane commands in a Docker container
# authenticates with the registry using env vars
# usage: crane_command <crane args>
#################################################
crane_command() {
    docker run --rm -t --network host \
        -e DOCKER_REGISTRY="$DOCKER_REGISTRY" \
        -e DOCKER_REGISTRY_USERNAME="$DOCKER_REGISTRY_USERNAME" \
        -e DOCKER_REGISTRY_TOKEN="$DOCKER_REGISTRY_TOKEN" \
        --entrypoint sh \
        gcr.io/go-containerregistry/crane:debug -c "
        crane auth login -u \$DOCKER_REGISTRY_USERNAME -p \$DOCKER_REGISTRY_TOKEN \$DOCKER_REGISTRY && crane $*"
}


#################################################
# push image with tags to remote docker image registry
#################################################
if [[ "${DOCKER_PUSH:-0}" == "1" ]]; then
   crane_command copy $local_registery/$image_name $docker_registry/$image_name

   if [[ $graalvm_version != *dev* ]]; then
      if [[ $java_major_version == "11" ]]; then
         crane_command copy $local_registery/$image_name $docker_registry/$image_repo:$graalvm_version-java$java_major_version  # e.g. 22.3.2-java11
      else
         crane_command copy $local_registery/$image_name $docker_registry/$image_repo:$graalvm_version # e.g. 17.0.7
      fi
   fi
fi
