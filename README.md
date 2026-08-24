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
| `Containerfile` | rarely | The build. Reasonable defaults; read it once. |
| `configs/.condarc` | rarely | Channels, and where user envs/pkgs live. |
| `configs/jupyter_server_config.py` | rarely | Jupyter server settings. |
| `scripts/start` | **no** | Entrypoint. See the warning below. |
| `.github/workflows/build.yaml` | once | Build + push. Set `REGISTRY`/`IMAGE`, add two secrets. |

Note that `.github/workflows/build.yaml` only runs once this directory is the
root of its own repository — GitHub only reads workflows from a repo root.

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
every pull request, and pushes it on `main`. It runs on GitHub's own
`ubuntu-latest` runners with a local builder, so it needs no NSF NCAR
infrastructure access — only a registry you can push to.

Two things to set up:

1. In the workflow's `env:` block, set `REGISTRY` and `IMAGE`.
2. Add two repository secrets under **Settings → Secrets and variables →
   Actions**:

   | Secret | What it is |
   |---|---|
   | `REGISTRY_USERNAME` | robot account or username for that registry |
   | `REGISTRY_PASSWORD` | its password or token |

Until those secrets exist the workflow still **builds** on every push and pull
request, it just does not push — which is a useful check on its own, since a
broken `environment.yml` fails there. Pull requests never push, so a PR is a
safe way to test a package change.

Where to push:

- **NSF NCAR Harbor** (`hub.k8s.ucar.edu`) — ask CISL for a project you can
  write to, plus a robot account for the two secrets.
- **This repo's GitHub Packages** (`ghcr.io`) — needs no secrets at all; the
  comments at the top of the workflow list the three lines to change. Handy for
  trying the build out before you have a Harbor project.

Every run finishes with a smoke test — Python version, `jupyterhub-singleuser`
version, kernel list, and a run as an arbitrary uid — against the image it just
built or pushed.

Two notes on hosted runners: they have 2 cores, so a cold conda solve is slow
(the workflow allows 120 minutes, and caches layers between runs), and the
build starts by deleting preinstalled toolchains to free disk. Both are
commented in the file.

If CISL has granted your repo access to the `CIRRUS-4x8` runner group and the
`buildkitd.arc-systems` endpoint, the workflow comments say how to switch back
to those — but that access is not the default and you should not assume it.

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
