#! /usr/bin/env bash

# change this
CONTAINER_IMAGE=sonarqube-operator

function print_usage() {
    echo "usage: $0 [(-b |--build=)(local|quay)] [(-p |--project=)QUAY_PROJECT] [(-t |--tag=)CONTAINER_TAG] [-l|--latest] [-d|--date] [-o|--operator] [-- BUILD_ARGS]" | fold -s
}

# parse args
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--build=*)
            if [ "$1" = '-b' ]; then
                shift
                BUILD="$1"
            else
                BUILD=$(echo "$1" | cut -d= -f2-)
            fi
            ;;
        -p|--project=*)
            if [ "$1" = '-p' ]; then
                shift
                QUAY_PROJECT="$1"
            else
                QUAY_PROJECT=$(echo "$1" | cut -d= -f2-)
            fi
            ;;
        -t|--tag=*)
            if [ "$1" = '-t' ]; then
                shift
                CONTAINER_TAG="$1"
            else
                CONTAINER_TAG=$(echo "$1" | cut -d= -f2-)
            fi
            ;;
        -l|--latest)
            TAG_ALSO_LATEST=true
            ;;
        -d|--date)
            BUILD_DATE=$(date +'%Y-%m-%d')
            ;;
        -o|--operator)
            OPERATOR_BUILD=true
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1" >&2
            print_usage >&2
            exit 127
            ;;
    esac
    shift
done

# some defaults
if [ -f .quay_creds -a -z "$BUILD" ]; then
    BUILD=quay
    . .quay_creds
elif [ -z "$BUILD" ]; then
    BUILD=local
fi
if [ -z "$QUAY_PROJECT" ]; then
    QUAY_PROJECT=redhatgov
fi
if [ -z "$CONTAINER_TAG" ]; then
    CONTAINER_TAG=latest
fi

# docker/podman problems
if ! which docker &>/dev/null; then
    if which podman &>/dev/null; then
        function docker() { podman "${@}" ; }
    else
        echo "No docker|podman installed :(" >&2
        exit 1
    fi
fi

# build and tag
function docker_build () {
    tags=("quay.io/$QUAY_PROJECT/$CONTAINER_IMAGE:$CONTAINER_TAG")
    if [ -n "$TAG_ALSO_LATEST" -a "$CONTAINER_TAG" != "latest" ]; then
        tags+=("quay.io/$QUAY_PROJECT/$CONTAINER_IMAGE:latest")
    fi
    args=("${@}")
    if [ -n "$BUILD_DATE" ]; then
        args+=("--build-arg=BUILD_DATE=$BUILD_DATE")
    fi

    if [ -n "$OPERATOR_BUILD" ]; then
        echo "Operator build" >&2
        if ! which operator-sdk &>/dev/null; then
            echo "No operator-sdk detected" >&2
            if [ -n "$VIRTUAL_ENV" ]; then
                echo "Installing operator-sdk-manager to virtualenv" >&2
                pip3 install --upgrade git+https://git.jharmison.com/jharmison/operator-sdk-manager || exit 120
                echo "Updating operator-sdk" >&2
                operator-sdk-manager update -vvvv
            else
                echo "Installing operator-sdk-manager for user" >&2
                pip3 install --upgrade --user git+https://git.jharmison.com/jharmison/operator-sdk-manager || exit 120
                echo "Updating operator-sdk" >&2
                $HOME/.local/bin/operator-sdk-manager update -vvvv
            fi
            echo "Building image" >&2
            $HOME/.local/bin/operator-sdk build --image-build-args "${args[*]}" "$CONTAINER_IMAGE:$CONTAINER_TAG" || exit 3
        else
            echo "Building image with preinstalled operator-sdk" >&2
            operator-sdk build --image-build-args "${args[*]}" "$CONTAINER_IMAGE:$CONTAINER_TAG" || exit 3
        fi
    else
        echo "Executing normal docker build of $CONTAINER_IMAGE:$CONTAINER_TAG" >&2
        docker build "${args[@]}" -t "$CONTAINER_IMAGE:$CONTAINER_TAG" . || exit 3
    fi

    for tag in "${tags[@]}"; do
        if [ "$tag" != "$CONTAINER_IMAGE:$CONTAINER_TAG" ]; then
            echo "Adding tag: $tag" >&2
            docker tag "$CONTAINER_IMAGE:$CONTAINER_TAG" "$tag"
        fi
    done
}

# build
case $BUILD in
    local)
        echo "LOCAL BUILD" >&2
        docker_build "${@}"
        ;;
    quay)
        echo "QUAY BUILD" >&2
        # designed to be used by travis-ci, where the docker_* variables are defined
        if [ -z "$DOCKER_PASSWORD" -o -z "$DOCKER_USERNAME" ]; then
            echo "Requires DOCKER_USERNAME and DOCKER_PASSWORD variables to be exported." >&2
            exit 1
        fi
        echo "...logging in." >&2
        echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin quay.io || exit 2

        docker_build "${@}"
        for tag in "${tags[@]}"; do
            echo "Pushing tag: $tag" >&2
            docker push "$tag" || exit 4
        done
        ;;
    *)
        print_usage >&2
        exit 126
        ;;
esac
