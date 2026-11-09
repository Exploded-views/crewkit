# The registry holder image

The registry holder is the one always-on machine that keeps the crew's registry: it pulls every
node's report, commits the result to the private sync repo, and runs the ntfy server that nodes
post "something changed" pointers to. It is one Docker image, so it runs wherever Docker does.
This page covers what the image holds, how to configure and run it, what `crewkit status` must
do for it, and what a compromised holder can do. The spend cap and the Fly steps come with the
spend-cap task.

## What the image holds

- A Debian base pinned by digest (`holder/Dockerfile`; `tools/lint-skills.py` fails on a base
  that is only a tag).
- The crewkit tree: `bin`, `libexec`, `lib`, `templates`.
- ntfy and tailscale, from the releases in `pins/ntfy.env` and `pins/tailscale.env`. The build
  checks each download against the sha256 in the pin, which is computed from the published file.
- `bash`, `git`, `jq`, `openssh-client`, `curl`, and `tini` as PID 1.

It has no agent CLI and no herdr. It runs as a non-root user (uid 10001). Nothing secret is in
any layer: `tools/holder-image-test.sh` checks `docker history`, `docker inspect` and the image
filesystem (with gitleaks) after every build. Build it with `tools/holder-image-build.sh`; the
Dockerfile's pin arguments have no defaults, so a bare `docker build` fails.

## What the entrypoint does

`libexec/crewkit-holder-run` runs these in order and stops with a message at the first failure:

1. Checks the settings and the secrets (below). A missing, unreadable or loose secret is exit
   78, naming the file and never a value.
2. Starts `tailscaled` and joins the tailnet with `tailscale up --authkey file:<path>`. The key
   never appears in argv or the environment. It always uses **userspace networking**: the image
   is non-root, and a non-root process cannot open a TUN device, so there is no `/dev/net/tun`
   mode. For each node in the `nodes` secret it writes an ssh `Host` block that goes through
   `tailscale nc` (the system resolver is not used, so MagicDNS names work only this way) and
   checks the node's host key strictly against the `nodes_known_hosts` secret; no other host is
   routed that way.
3. Starts `ntfy serve` on **loopback**, with `auth-default-access: deny-all`
   (`holder/ntfy-server.yml`). In userspace networking no interface carries the tailnet address,
   and tailscaled delivers connections to the holder's tailnet address to `127.0.0.1` on the same
   port, so this is reachable from the tailnet and from nothing else. Its user database is a
   private copy of the `ntfy_auth` secret.
4. Fetches or clones the sync repo with the deploy key, checks that its `registry.json` has
   `CK_REGISTRY_ID`, and writes `registry.dir`, `registry.remote` and, for each node in the
   `nodes` secret, `nodes.<name>.host` and `nodes.<name>.node_id` to the holder's user settings
   file. On a restart the working copy is kept and brought up to date; unpushed local
   commits that cannot fast-forward are kept on a `holder-aside-<time>` branch, and a half-written
   clone is replaced.
5. Loops: every `CK_POLL_SECONDS` it runs `crewkit status --pull` (every node); when a node name
   arrives on the pointer pipe (`<state>/pointers`) it runs `crewkit status --pull NODE`. A line
   on the pipe that is not a node name (`^[a-z][a-z0-9-]{0,31}$`) is dropped. The status table is
   not logged.

It exits non-zero when `tailscaled` or `ntfy` dies, and the host's restart policy brings it
back. It never runs an agent, a login shell, or anything on a node but the pull, and the pull's
only remote command is the node's forced `crewkit node report`.

## What `crewkit status` must do for the holder

The holder is not a joined node: it has no node state, only the registry clone. These are the
inputs the entrypoint gives `crewkit status`, and the status task implements and tests them:

- It is called as `crewkit status --pull [NODE]`, with `CK_HOLDER=1` in the environment. In that
  mode it takes the registry from `registry.dir`, pulls the named node's report (or every node's),
  records it, commits and pushes (debounced as usual), and prints nothing the holder needs.
- `CK_REPORT_KEYS` is the directory of per-node report keys; the ssh to node `N` uses
  `-i $CK_REPORT_KEYS/<node_id of N> -o IdentitiesOnly=yes`, with the node's forced command.
- `GIT_SSH_COMMAND` is set by the holder and carries the deploy key and the host-key policy. The
  registry functions must keep an existing `GIT_SSH_COMMAND` and never replace it with their own,
  or pulls and pushes lose the key.
- The node's host and id come from the `nodes.<name>.host` and `.node_id` settings above, never
  from the sync repo. ssh to that host needs nothing more from `status`: `~/.ssh/config` already
  routes it through tailscaled and checks its key. `status` must not add `-F`, a `ProxyCommand` or
  its own host-key options for it.

## Configuration

Environment:

| Name | Default | Meaning |
|---|---|---|
| `CK_REGISTRY_REMOTE` | required | The sync repo's URL. Letters, digits and `@ : / . _ ~ + % -` only. |
| `CK_REGISTRY_ID` | required | The registry's id; the sync repo must carry the same. |
| `CK_HOLDER_NAME` | required | The holder's tailnet hostname (a codename). |
| `CK_POLL_SECONDS` | `600` | How often every node is pulled, pointer or not. |
| `CK_NTFY_PORT` | `8080` | ntfy's port. |

Secrets are files under `/run/secrets/`, each mode 600 or 400 and readable by the user the
container runs as:

| File | Holds |
|---|---|
| `deploy_key` | An ssh key for the sync repo, and nothing else. |
| `known_hosts` | The sync repo host's key, needed when `CK_REGISTRY_REMOTE` is reached over ssh (anything but a local path, `file://` or `https://`). The check is strict; there is no trust on first use. |
| `nodes` | The nodes to pull from, one per line: `NAME NODE_ID [USER@]HOST` (blank lines and whole-line `#` comments are fine; a name twice, or a node with no `report_keys/<node_id>` file, is refused). The reach info is kept out of the sync repo; `crewkit registry move` and `crewkit join` produce this file for the holder. |
| `nodes_known_hosts` | The nodes' ssh host keys, in `known_hosts` format, keyed by the host exactly as written in `nodes` (`homebox`, not its IP address: ssh looks the key up under the name it was given). The check is strict. |
| `report_keys/<node_id>` | One forced-command key per node, used only to run `crewkit node report`. |
| `ntfy_auth` | ntfy's user and token database (made by `crewkit holder tokens`). |
| `ts_authkey` | A Tailscale auth key. Make it reusable, or make the holder's node ephemeral: the tailscale state is not kept, so every new container registers again, and a single-use key fails the second time. |

## Running it

```console
docker run -d --restart on-failure --read-only --tmpfs /tmp \
  --tmpfs /var/lib/crewkit-holder:uid=10001,mode=700 --tmpfs /home/crewkit:uid=10001,mode=700 \
  -v <secrets dir>:/run/secrets:ro \
  -e CK_REGISTRY_REMOTE=<sync repo url> -e CK_REGISTRY_ID=<registry id> -e CK_HOLDER_NAME=<holder name> \
  <image>
```

- The state and home directories must be writable: `--read-only` needs the two `--tmpfs` lines
  (or leave `--read-only` off).
- The secret files must be owned by uid 10001 with mode 600 or 400 (`chown 10001` the directory).
  A bind-mounted file keeps its host owner. Do not run with a different `--user`: ssh looks the
  user up in the passwd file for its config, and an unknown uid makes it exit.
- On a Swarm, create each secret with `uid: "10001"` and `mode: 0400` in the service's `secrets`
  entry; the default (root, 0444) is refused.
- The image runs `tini` itself, so `--init` is not needed.
- Tailscale runs in userspace, so no `--device /dev/net/tun`, `NET_ADMIN` or privileged mode is
  needed or used.
- Fly has its own steps, which are in the spend-cap task.

## What a compromised holder can do

It holds the sync repo's deploy key, the per-node report keys and the ntfy database.

- It can read and rewrite the registry, which is state, not authority: a node never acts on it.
- It can run `crewkit node report` on each node, and nothing else: each node's `authorized_keys`
  line forces that command with `restrict`.
- It can post and read pointers on its own ntfy server.
- It can never control a node: no login shell, no herdr access, no way to type into a pane.

Recovery: replace the report keys on each node (`crewkit node authorize`), rotate the deploy
key and the ntfy tokens, and move the registry to a fresh holder (`crewkit registry move`).
