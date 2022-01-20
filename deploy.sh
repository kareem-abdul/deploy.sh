#!/bin/bash


usage() {
  cat <<doc
Usage: $(basename "$0") serverAddress [OPTIONS]

  used to deploy a docker-compose based project in the current directory to a server via ssh

  serverAddress: the address of the ssh server,
                eg: user@serverdomain or user@serverIp
                If the serverAddress is configured in the .ssh/config
                file then you can use the Host name here instead of the full address

Options:

  -h                 : prints help
  --ignore file      : File containing the patterns that ignore files while deploying the current directory.
                        If .gitignore file is present in the current directory, then it is used by default if
                        not explicitly specified
  -e envFile         : An env file for the docker compose, this env file is pasted to the current directory.
                        By default if a .env file is present in the current directory, it is used.
                        Note this has only effect if either the env_file section in the docker-compose.yml
                        has the same name as envFile, or environment variables are explicitly specified on the environment section
  -f                 : follow logs of deployed docker container
  --no-save          : don't save logs of already running container on the server
  --target folder    : the target folder to deploy, by default the current folder in which the script executes is used
  --compose file     : the docker compose file to use by default it uses file named docker-compose.yml in the target folder

doc
  return 0;
}

[ "$1" = "-h" ] && usage && exit 0

err() { echo "$@" >&2; usage; exit 1; }

serverOriginal="$1"
server="$1"
[ -z "$server" ] && usage && exit 1
if ! [[ $server =~ (\w+)?@([0-9.]+) ]]; then # extract from ssh config
  [ ! -f ~/.ssh/config ] && err "$server not found"
  grep -q "^Host $server" ~/.ssh/config || err "$server not found"
  server="$(ssh -G "$server" | grep "^user " | cut -f2 -d ' ')@$(ssh -G "$server" | grep "^hostname " | cut -f2 -d ' ')"
fi
shift;

username=$(echo "$server" | cut -d@ -f1)
ignore=""
envFile=""
followLogs=0
saveLogs=1
targetDir=""
composeFile=""

need_arg() {
  # indirect substitution. source: https://unix.stackexchange.com/questions/41292/variable-substitution-with-an-exclamation-mark-in-bash/41293#41293
  OPTARG=$([ $# -ge $OPTIND ] && echo "${!OPTIND}" || echo "")
  (( ++OPTIND ))
  [ -z "$OPTARG" ] && err "$(basename "$0"): option requires an argument -- --$OPT"
}

while getopts "de:g:f-:" OPT
do
  if [ "$OPT" = "-" ]; then # adds support for long args in getopts (along with need_args)
    OPT="${OPTARG}"
  fi
  case "${OPT}" in
    e)       envFile="$OPTARG"; [ ! -f  "$envFile" ] && err "$envFile does not exists"; ;;
    f)       followLogs=1; ;;
    no-save) saveLogs=0; ;;
    ignore)  need_arg "$@"; ignore="$OPTARG"; [ ! -f "$ignore" ] && err "$ignore does not exists"; ;;
    target)  need_arg "$@"; targetDir="$OPTARG"; [ ! -d "$targetDir" ] && err "$targetDir does not exists"; ;;
    compose) need_arg "$@"; composeFile="$OPTARG"; [ ! -f "$composeFile" ] && err "$composeFile does not exists"; ;;
    ??* )    err "$(basename "$0"): illegal option -- --$OPT" ;;
    ?)       err ;;
  esac
done

[ -z "$targetDir" ] && targetDir="$(pwd)"
cd "$targetDir"
base=$(basename "$PWD")
[ -z "$ignore" ] && ignore="$base/.gitignore"
[ -z "$envFile" ] && envFile="$base/.env"
[ -z "$composeFile" ] && composeFile="docker-compose.yml";
if [ -f "$composeFile" ]; then
  cp "$composeFile" "$(pwd)/docker-compose-tmp.yml"
  composeFile="docker-compose-tmp.yml"
else
  err "docker compose file not found"
fi
cd ..
if [ -f "$envFile" ]; then
  cp "$envFile" "$(pwd)/$base/.env.tmp"
  envFile=".env.tmp"
fi
tar -c --exclude=node_modules --exclude=.git $(test -e "$ignore" && echo "-X $ignore") -zvf "$base.tar.gz" "$base"
[ -f "$base/$envFile" ] && rm "$base/$envFile"
[ -f "$base/$composeFile" ] && rm "$base/$composeFile"
scp "$base.tar.gz" "$serverOriginal:$base.tar.gz"
rm "$base.tar.gz"

script="$(cat <<EOF
  if [ -d "$base" ]; then
    cd $base
    if [ $saveLogs -eq 1 ]; then
      docker-compose logs > "$base.$(date "+%F%T").log"
      [ ! -d "../logs" ] && mkdir "../logs"
      mv $base.*.log "../logs/"
    fi
    docker-compose down || true
    cd ..
    rm -rf $base
  fi
  tar -xzf "$base.tar.gz"
  rm "$base.tar.gz"
  cd $base
  if [ -f "$envFile" ]
  then
    docker-compose -f "$composeFile" --env-file "$envFile" up --build -d --no-deps
  else
    docker-compose -f "$composeFile" up --build -d --no-deps
  fi
  [ $followLogs -ne 0 ] && docker-compose logs -f
EOF
)"
ssh -q -t "$serverOriginal" "$script"
