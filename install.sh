#!/usr/bin/env bash
# Install Eradani Personas on a blank Debian or Ubuntu server: clone the newest release tag over SSH
# with a read-only deploy key this server makes, then run the checkout's install.sh.
#   curl -fsSL <url> | sudo bash -s -- [--ref <tag|branch>] [--clone-only] [-- <install.sh args>]
# PERSONAS_REPO and PERSONAS_KNOWN_HOSTS (a file replacing GitHub's keys) override the repo and host keys.
set -euo pipefail

readonly ETC=/etc/eradani-personas
readonly KEY=$ETC/deploy-key
readonly KNOWN_HOSTS=$ETC/known_hosts
readonly DEST=/opt/eradani-personas
readonly DEFAULT_REPO=git@github.com:eradani-inc/eradani-personas.git

die() { local code=$1; shift; printf 'install: %s\n' "$*" >&2; exit "$code"; }

probe_uid() { id -u; }
probe_has() { command -v "$1" >/dev/null 2>&1; }
probe_id() { sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"'; }
probe_installed() { [[ -e $DEST/.git ]]; }

install_packages() {
  {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git openssh-client
  } || die 1 "couldn't install git and openssh-client with apt"
}

github_keys() {
  cat <<'KEYS'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
KEYS
}

prepare_ssh() {
  install -d -m 755 "$ETC"
  if [[ -n ${PERSONAS_KNOWN_HOSTS:-} ]]; then cat "$PERSONAS_KNOWN_HOSTS"; else github_keys; fi >"$KNOWN_HOSTS"
  [[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "eradani-personas-deploy@$(hostname -s)" -f "$KEY"
}

public_key() { cat "$KEY.pub"; }

ls_remote() { git ls-remote --tags --sort=-v:refname "$1" 'v*'; }

pick_tag() { sed -n 's|^[0-9a-f]\{40,\}[[:space:]]refs/tags/\(v[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)$|\1|;T;p;q'; }

clone() {
  tmp=$(mktemp -d /opt/.eradani-personas.XXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  chmod 755 "$tmp" # mktemp makes it 0700, and the containers read the checkout
  git -c advice.detachedHead=false clone --quiet --branch "$2" "$1" "$tmp" \
    || die 1 "couldn't clone $2 from $1"
  git -C "$tmp" config core.sshCommand "$GIT_SSH_COMMAND"
  mv -T "$tmp" "$DEST"
  trap - EXIT
  echo "install: cloned $2 ($(git -C "$DEST" rev-parse --short=12 HEAD)) into $DEST"
}

run_install() { exec "$DEST/install.sh" "$@"; }

# ssh's refusals of a host key that isn't the one in $KNOWN_HOSTS, which say nothing of the deploy key
host_key_refused() { grep -qE 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' <<<"$1"; }

refuse_until_key_added() {
  local repo=$1 slug=$1
  [[ $repo =~ github\.com[:/]([^/]+/[^/]+)$ ]] && slug=${BASH_REMATCH[1]%.git}
  {
    echo "install: cannot read $repo with this server's deploy key yet."
    echo "add this deploy key to $slug"
    public_key
    if [[ $repo == *github.com[:/]* ]]; then
      echo "open https://github.com/$slug/settings/keys/new, paste the key above and tick nothing (read-only is the default)"
    fi
    echo "then run this again"
  } >&2
  exit 11
}

main() {
  local ref='' clone_only=0 repo=${PERSONAS_REPO:-$DEFAULT_REPO} listing
  while (($#)); do
    case $1 in
      --ref) (($# >= 2)) || die 2 "--ref needs a tag or branch"; ref=$2; shift 2 ;;
      --clone-only) clone_only=1; shift ;;
      --) shift; break ;;
      *) die 2 "unknown argument $1; usage: bash -s -- [--ref <tag|branch>] [--clone-only] [-- <install.sh args>]" ;;
    esac
  done
  [[ $(probe_uid) == 0 ]] || die 10 "run this as root, for example with sudo bash"
  if ! probe_has git || ! probe_has ssh-keygen; then
    probe_has apt-get || die 10 "this server is $(probe_id), and the stub installs git and openssh-client only with apt; install them and run this again"
    install_packages
  fi
  prepare_ssh
  # An https remote would otherwise make git ask for a username on the terminal.
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes"
  if probe_installed; then
    echo "install: $DEST is there; baton update changes its version"
  else
    # On failure the listing holds ssh's and git's own words; on success they are only warnings,
    # which pick_tag skips.
    if ! listing=$(ls_remote "$repo" 2>&1); then
      [[ -z $listing ]] || printf '%s\n' "$listing" >&2
      if host_key_refused "$listing"; then
        die 1 "the host key $repo presents isn't one this script trusts (GitHub's, or those in the file PERSONAS_KNOWN_HOSTS names), so nothing was read. If the host changed its key, put the new key in a file of your own, not $KNOWN_HOSTS, which each run rewrites, and run this again with PERSONAS_KNOWN_HOSTS set to that file"
      fi
      refuse_until_key_added "$repo"
    fi
    [[ -n $ref ]] || ref=$(pick_tag <<<"$listing")
    [[ -n $ref ]] || die 1 "no vX.Y.Z tag in $repo"
    clone "$repo" "$ref"
  fi
  if ((clone_only)); then exit 0; fi
  run_install "$@"
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
