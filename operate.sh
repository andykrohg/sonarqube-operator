#!/bin/bash

cd $(dirname $(realpath $0))

function now() {
    date '+%Y%m%dT%H%M%S'
}
# Error handler
function on_error() {
    [ -n "$msg" ] && wrap "$msg" ||:
    echo
    now=$(now)
    mv $log error_$now.log
    chmod 644 error_$now.log
    sync
    wrap "Error on $0 line $1, logs available at error_$now.log" >&2
    [ $1 -eq 0 ] && : || exit $2
}

# Generic exit cleanup helper
function on_exit() {
    rm -f $log
}

# Stage some logging
log=$(mktemp)
if echo "$*" | grep -qF -- '-v' || echo "$*" | grep -qF -- '--verbose'; then
    exec 7> >(tee -a "$log" |& sed 's/^/\n/' >&2)
    FORMATTER_PAD_RESULT=0
else
    exec 7>$log
fi
echo "Logging initialized $(now)" >&7

# Set some traps
trap 'on_error $LINENO $?' ERR
trap 'on_exit' EXIT

# Get some output helpers to keep things clean-ish
if which formatter &>/dev/null; then
    # I keep this on my system. If you want, you can install it yourself:
    #   mkdir -p ~/.local/bin
    #   curl -o ~/.local/bin/formatter https://raw.githubusercontent.com/solacelost/output-formatter/modern-only/formatter
    #   chmod +x ~/.local/bin/formatter
    #   echo "$PATH" | grep -qF "$(realpath ~/.local/bin)" || export PATH="$(realpath ~/.local/bin):$PATH"
    . $(which formatter)
else
    # These will work as a poor-man's approximation in just a few lines
    function error_run() {
        echo -n "$1"
        shift
        eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [  ERROR  ]' ; return $ret ; }
    }
    function warn_run() {
        echo -n "$1"
        shift
        eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [ WARNING ]' ; return $ret ; }
    }
    function wrap() {
        if [ $# -gt 0 ]; then
            echo "${@}" | fold -s
        else
            fold -s
        fi
    }
fi

function print_usage() {
    wrap "usage: $(basename $0) [-h|--help] | [-r|--remove] [-v|--verbose] " \
         "[(-k |--kind=)KIND] [(-i |--image=)IMG]"
}

function print_help() {
    print_usage
    cat << EOF

Build an ansible-based operator using only requirements.yml, watches.yml, and
the requisite playbooks/ and roles/ files on the fly. Can be applied to a
cluster directly, packaged into a bundle, or kustomized.

OPTIONS
    -h|--help                       Print this help page and exit.
    -r|--remove                     Remove any installed/built operator and
                                      artifacts of that build.
    -v|--verbose                    Output all command output directly to
                                      stderr, making it ugly but debuggable.
    -i |--image=IMG                 Set the image name for the operator to IMG
    -k |--kind=KIND                 Set the Kind of the CRD to KIND
EOF
}

function parse_arg() {
    # If the first arg = the second arg, output the third and fail, otherwise
    #   split the second on the first `=` sign and succeed.
    # ex:
    #   -i|--image=*)
    #       IMG=$(parse_arg -i "$1" "$2") || shift
    if [ "$1" = "$2" ]; then
        echo "$3"
        return 1
    else
        echo "$2" | cut -d= -f2-
        return 0
    fi
}

# Unset defaults
REMOVE_OPERATOR=
IMG=
KIND=

# Load the configuration
if [ -f operate.conf ]; then
    warn_run "Loading configuration from operate.conf" $(python -c 'import configparser
config = configparser.ConfigParser()
config.read("operate.conf")
print("\n".join([
    f"export {k.upper()}=\"{v}\""
    for k, v in config["operator"].items()
]))')
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -r|--remove)
            REMOVE_OPERATOR=true
            ;;
        -v|--verbose)
            true
            ;;
        -i|--image=*)
            IMG=$(parse_arg -i "$1" "$2") || shift
            export IMG
            ;;
        -k|--kind=*)
            KIND=$(parse_arg -k "$1" "$2") || shift
            export KIND
            ;;
        *)
            print_usage >&2
            exit 127
            ;;
    esac ; shift
done

if [ "$REMOVE_OPERATOR" ]; then
    warn_run "Removing operator files" rm -rf PROJECT Makefile Dockerfile bin config molecule ||:

    exit $?
fi

error_run "Updating the Operator SDK manager" pip install --user --upgrade git+https://git.jharmison.com/jharmison/operator-sdk-manager.git
error_run "Updating the Operator SDK" 'version=$(operator-sdk-manager update -vvvv | cut -d" " -f 3)'
error_run "Initializing Ansible Operator with operator-sdk $version" operator-sdk init --plugins=ansible --domain=io
error_run "Creating API config with operator-sdk $version" operator-sdk create api --group redhatgov --version v1alpha1 --kind $KIND
if which kubectl &>/dev/null; then
    if kubectl get nodes &>/dev/null; then
        for tag in 1.0.0 latest; do
            error_run "Building tag $tag" make docker-build IMG=$IMG:$tag
            error_run "Pushing tag $tag" make docker-push IMG=$IMG:$tag
        done
        error_run "Installing operator resources" make install
        error_run "Deploying operator" make deploy IMG=$IMG:latest
    else
        warn_run "No kubernetes credentials cached?" false
    fi
else
    warn_run "kubectl not in path" false
fi
