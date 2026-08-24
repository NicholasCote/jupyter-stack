# CIRRUS JupyterHub — custom notebook image template

A starting point for building your own notebook image for the NSF NCAR CIRRUS
JupyterHub. Clone it, add your packages, push, and select the image on the hub.

It is a **single self-contained build**: there is no CIRRUS parent image to keep
in sync. One `Containerfile` produces one conda environment containing both the
Jupyter/hub machinery and your packages.

## First, do you actually need an image?

Often not. The image ships `nb_conda_kernels` with `~/my-conda-envs` on the
conda search path, so an environment created in your home directory shows up as
a Jupyter kernel with no image at all:

```bash
conda create -p ~/my-conda-envs/myproject python=3.12 ipykernel numpy pandas
```

Reload JupyterLab and `myproject` appears in the kernel picker.

Build a custom image when you need compiled/system-level dependencies, a large
stack you want to start fast, or one environment shared across a group.

## Layout

| Path | You edit it? | What it is |
|---|---|---|
| `environment.yml` | **yes** | Your conda/pip packages. The main file. |
| `apt.txt` | sometimes | Extra OS packages. |
| `npm.txt` | sometimes | Global npm packages. Jupyter AI agents go here. |
| `persona/` | rarely | Registers the NCAR model as a Jupyter AI agent. |
| `Containerfile` | rarely | The build. Reasonable defaults; read it once. |
| `configs/.condarc` | rarely | Channels, and where user envs/pkgs live. |
| `configs/jupyter_server_config.py` | rarely | Jupyter server settings. |
| `scripts/start` | **no** | Entrypoint. See the warning below. |
| `.github/workflows/build.yaml` | once | Build + push. Set `REGISTRY`/`IMAGE`, add two secrets. |

## Adding packages

Open `environment.yml` and add under the `YOUR PACKAGES GO BELOW` marker. There
are commented-out starting points for a scientific Python stack, dask, and
pip-only packages.

**Two rules that matter:**

1. **Do not change `jupyterhub-singleuser=5.2.1`.** It has to match the running
   hub or your server will not launch. Change it only when CISL announces a hub
   upgrade.
2. **Do not add tight pins for `jupyterlab_server`, `jupyter_server`, or
   `notebook`.** Pinning those alongside a pinned `jupyterlab` is exactly what
   makes the solve fail. Let conda pick them.

### Choosing an AI agent

Jupyter AI's chat has an agent picker. This image ships four:

| Agent | Backed by | Account needed |
|---|---|---|
| **Qwen (NCAR)** | the NSF NCAR-hosted model | **none** |
| **Claude** | `api.anthropic.com` | Anthropic |
| **Codex** | OpenAI | OpenAI or ChatGPT |
| **Copilot** | GitHub | GitHub |

Qwen works immediately and needs no credentials, so nobody is blocked on having
a commercial account. The other three each need you to sign in once.

**Signing in.** Agents run as child processes of the Jupyter *server*, so an
environment variable exported in a terminal reaches only that terminal. Put it
in `~/.bash_profile`, which the entrypoint sources before starting the server,
then restart your server:

```bash
printf 'export OPENAI_API_KEY=sk-...\n' >> ~/.bash_profile
chmod 600 ~/.bash_profile
```

`~/.bashrc` will **not** work — a login shell does not read it.

The CLI login commands are an alternative to keys, and they store credentials
under your home directory, which persists across server restarts:

- **Copilot** — `copilot login` in a terminal. Or set `COPILOT_GITHUB_TOKEN`,
  `GH_TOKEN`, or `GITHUB_TOKEN`.
- **Codex** — `codex login` to use a ChatGPT account. Or set `OPENAI_API_KEY`
  or `CODEX_API_KEY`.
- **Claude** — `claude /login` signs the CLI in to a Claude.ai account, which
  is useful for using Claude Code in a terminal. It may not be enough for the
  Claude *agent*: Anthropic does not permit third-party tools built on the
  Claude Agent SDK to use Claude.ai logins without prior approval, so the agent
  may still require `ANTHROPIC_API_KEY` from `console.anthropic.com`.

Restart the server after any of these.

**The NCAR endpoint.** The Qwen agent is the stock Claude adapter aimed at an
internally hosted model rather than Anthropic — see `scripts/qwen-agent-acp`
and `persona/`. It is reachable as both `qwen.k8s.ucar.edu` and
`llm.k8s.ucar.edu`. Both the host and the model name can be changed at runtime,
without rebuilding, through `NCAR_MODEL_BASE_URL` and `NCAR_MODEL_NAME`.

To drop an agent, delete its line from `npm.txt` — Jupyter AI finds agents by
looking for their executable, so removing the package removes the agent and
nothing else.

### npm packages, and Jupyter AI agents

Jupyter AI ships with **no agents** — each one is a separate npm package that
you install yourself. They have to go in the image: at runtime `/srv/conda` is
read-only, so `npm install -g` in a terminal fails with `EACCES` no matter what
you try.

List them in `npm.txt`, one per line, and make sure `nodejs` is in
`environment.yml` (the build stops with a clear message if it is missing):

```
@agentclientprotocol/claude-agent-acp
```

`npm install -g` resolves to this image's conda environment, so the agent lands
on every user's `PATH`. The build skips this step entirely when `npm.txt` has no
entries, so you only pay for it if you use it.

Agents need credentials at runtime — an API key or a login. Provide those
per-user through the hub environment or the user's home directory; do not bake a
key into the image, where every user of it would share yours. The agent also
needs outbound network access to its provider, which is worth confirming with
CISL before you debug it as an image problem.

For reproducibility, generate a lock file instead of hand-pinning:

```bash
conda-lock lock --file environment.yml --platform linux-64
```

then commit it and have the `Containerfile` install from the lock. The
`pangeo-notebook/` directory in the NCAR/cirrus-jhub-images repo shows that
pattern in use.

## Build and test locally

```bash
podman build -f Containerfile -t my-notebook:dev .        # or docker
```

Smoke-test it before pushing — this catches most breakage:

```bash
# Does the environment work and is the hub package the right version?
podman run --rm my-notebook:dev python -c "import sys; print(sys.version)"
podman run --rm my-notebook:dev jupyterhub-singleuser --version
podman run --rm my-notebook:dev jupyter kernelspec list

# Does the server actually come up? Then open the printed URL.
podman run --rm -p 8888:8888 my-notebook:dev jupyter lab --ip=0.0.0.0 --no-browser
```

The last one matters most: a broken entrypoint or a missing hub package only
shows up when the server tries to start.

Test as a non-default uid too, because that is how the hub runs it:

```bash
podman run --rm --user 12345 my-notebook:dev python -c "print('ok')"
```

## Automated builds (GitHub Actions)

`.github/workflows/build.yaml` builds the image on every push to `main` and on
every pull request, and pushes it to a registry on `main`. It runs on GitHub's
own runners, so there is nothing to install and nothing to arrange first.

To turn pushing on:

1. In the workflow's `env:` block, set `REGISTRY` and `IMAGE` to where your
   image should go. For NSF NCAR Harbor that is `hub.k8s.ucar.edu` and
   `your-project/your-image-name` — ask CISL for a project you can push to and
   a robot account to push with.
2. Add two repository secrets under **Settings → Secrets and variables →
   Actions**:

   | Secret | What it is |
   |---|---|
   | `REGISTRY_USERNAME` | the robot account or username |
   | `REGISTRY_PASSWORD` | its password or token |

Until both secrets exist the workflow still **builds** the image on every push
and pull request — it just does not push it anywhere. That is worth having on
its own: a typo or an unsolvable `environment.yml` fails there, in a log you can
read, instead of when you try to launch a server.

Pull requests never push, so opening one is a safe way to check a package change
before it reaches `latest`.

Each pushed build gets two tags: `latest` and the short commit sha. The first
build takes a while; after that, unchanged layers come from the cache.

## How OOD launches this image

Open OnDemand overrides four of the image's environment variables at runtime
with the real user's values:

```yaml
env:
  NB_UID:  "<%= user.uid %>"
  NB_USER: "<%= user.name %>"
  NB_GID:  "<%= user.group.id %>"
  HOME:    "<%= user.home %>"
```

What that means for the image:

- **`HOME` is the user's real home**, not `/home/jovyan`. Anything in the image
  that needs to follow the user is written as `~` rather than a literal path —
  see `envs_dirs` and `pkgs_dirs` in `configs/.condarc`, which is why
  `~/my-conda-envs` works without knowing the path at build time.
- **`scripts/start` cds to `$HOME`** before starting the server. The image is
  built with `WORKDIR /home/jovyan`, and Jupyter serves files from the working
  directory, so without that step users would see the image's empty placeholder
  home instead of their own files.
- **`NB_USER`/`NB_UID`/`NB_GID` are informational to the image.** Setting them
  does not change the uid the process runs as — that comes from the pod's
  `runAsUser`/`runAsGroup`. `scripts/start` prints a warning naming both if the
  home directory turns out not to be writable, which is the symptom of those two
  disagreeing.

**The pod must run as the user's uid.** Environment variables alone will not do
it. If the container runs as the image's default uid 1000 while `HOME` points at
a directory owned by the real user, the user cannot write to their own home.
The image will not try to fix this itself: switching users requires root, and an
entrypoint that attempts it fails immediately (see the warning below).

If you hit errors mentioning **"no passwd entry for uid"**, that is a uid with no
`/etc/passwd` record. Most tools do not care as long as `HOME` is set, but a few
(some `ssh` and `git` paths) do. Ask CISL about it rather than adding a `useradd`
to `scripts/start`.

## A warning about `scripts/start`

The entrypoint is deliberately two lines:

```bash
#!/bin/bash -l
exec "$@"
```

The `-l` makes it a login shell, which activates the conda environment before
the server starts. That is all it needs to do.

Do **not** add `useradd`, `groupadd`, `chown`, `gosu`, or `sudo` to it. The
container runs as a uid assigned by the hub, with no permission to do any of
those things, and the failed attempt makes the container exit immediately at
startup with an error that is hard to read. This is a real failure mode that has
bitten these images before.

## What is deliberately not here

Kept out to keep the template small. All of these exist in
`notebook-images/Containerfile` in the NCAR/cirrus-jhub-images repo — copy from
there if you need them:

- **code-server** (VS Code in the browser) — two build steps plus a launcher
  tile in `configs/jupyter_server_config.py`.
- **R / IRkernel** — see `notebook-images/conda/r-4.4.yml`.
- **CUDA / cuDNN, TensorFlow, PyTorch** — see the `gpu-nb`, `tf-nb`, and
  `torch-nb` stages.
- **dask** — one uncommented block away in `environment.yml`.

## Using your image on CIRRUS

Push it (the workflow does this on merge to `main`, once its two registry
secrets are set), then select it on the hub's server-options page. Pin a
specific tag rather than `latest` for anything you depend on — `latest` moves
under you on the next merge.

## Getting help

Open an issue on this repo or contact CISL Help. Useful details: the image tag,
the build log, and the output of the smoke tests above.
