# =============================================================================
# CIRRUS JupyterHub - custom notebook image template
#
# A single, self-contained build. There is no CIRRUS parent image to stay in
# sync with: this starts from ubuntu:24.04 and builds one conda environment
# that contains both the Jupyter/hub machinery and your packages.
#
# In normal use you edit exactly two files:
#   environment.yml   your packages (add to the bottom)
#   apt.txt           extra OS packages, if you need any
#
# Build locally:
#   podman build -f Containerfile -t my-notebook:dev .
# Run locally:
#   podman run --rm -p 8888:8888 my-notebook:dev jupyter lab --ip=0.0.0.0
# =============================================================================
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="CIRRUS JupyterHub custom notebook"
LABEL org.opencontainers.image.description="Custom single-user notebook image for the NSF NCAR CIRRUS JupyterHub"
LABEL org.opencontainers.image.licenses="MIT"

# Use bash, and fail a pipeline if any stage of it fails.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# NB_USER / NB_UID / NB_GID / HOME are BUILD-TIME defaults only. Open OnDemand
# overrides all four at runtime with the real user's values, so nothing in this
# image may depend on them being jovyan/1000. Paths that must follow the user at
# runtime are written as `~` (see configs/.condarc), which expands via $HOME.
ENV CONDA_ENV=notebook \
    CONDA_VER=26.1.1-3 \
    CONDA_DIR=/srv/conda \
    DEBIAN_FRONTEND=noninteractive \
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=1000 \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Vars that reference other vars need to be in their own ENV block.
ENV NB_PYTHON_PREFIX=${CONDA_DIR}/envs/${CONDA_ENV} \
    HOME=/home/${NB_USER}

# The notebook env comes first, so `python` and `jupyter` resolve to it.
ENV PATH=${NB_PYTHON_PREFIX}/bin:${CONDA_DIR}/bin:${PATH}

# Point dask at a config dir that root owns and users can read.
ENV DASK_ROOT_CONFIG=${CONDA_DIR}/etc

# --- OS packages -------------------------------------------------------------
# Comments and blank lines in apt.txt are stripped, so it can be annotated.
COPY apt.txt /tmp/apt.txt
RUN echo "Installing apt packages..." \
    && apt-get update --fix-missing \
    && apt-get install -y apt-utils ca-certificates wget \
    && { grep -vE '^[[:space:]]*(#|$)' /tmp/apt.txt || true; } | xargs -r apt-get install -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt.txt

# --- non-root user -----------------------------------------------------------
# /srv is deliberately left owned by root, so the environment is read-only to
# users at runtime. Anything a user installs goes in ~/my-conda-envs instead.
RUN echo "Creating ${NB_USER}..." \
    && (userdel -r ubuntu 2>/dev/null || true) \
    && groupadd --gid ${NB_GID} ${NB_USER} \
    && useradd --create-home --gid ${NB_GID} --no-log-init --uid ${NB_UID} ${NB_USER}

# --- conda -------------------------------------------------------------------
RUN echo "Installing Miniforge ${CONDA_VER}..." \
    && wget --quiet "https://github.com/conda-forge/miniforge/releases/download/${CONDA_VER}/Miniforge3-${CONDA_VER}-Linux-x86_64.sh" -O /tmp/installer.sh \
    && /bin/bash /tmp/installer.sh -u -b -p "${CONDA_DIR}" \
    && rm /tmp/installer.sh \
    && "${CONDA_DIR}/bin/conda" clean -afy

# --- the environment ---------------------------------------------------------
# Installed by prefix, so editing `name:` in environment.yml cannot break PATH.
# The channel list comes from environment.yml itself, so .condarc is not needed
# for the solve - and is deliberately installed afterwards, because its
# pkgs_dirs points into the user's home, which root must not write to here.
COPY environment.yml /tmp/environment.yml
RUN echo "Building the ${CONDA_ENV} environment..." \
    && mamba env create --prefix "${NB_PYTHON_PREFIX}" -f /tmp/environment.yml \
    && mamba clean -afy \
    # Static libraries are dead weight in an image. Note that .pyc files are
    # deliberately NOT deleted - removing them measurably slows notebook start.
    && find "${CONDA_DIR}" -follow -type f -name '*.a' -delete \
    && rm /tmp/environment.yml

# Two fixes for the home directory, after all the root-owned writes above:
#  - conda writes ~/.conda/environments.txt as root while building the env, so
#    hand ownership back;
#  - useradd creates the home dir 0750, which means a pod running as any other
#    uid cannot even read ~/.bash_profile and logs a confusing "Permission
#    denied" on every shell start. 0755 keeps that quiet.
RUN chown -R ${NB_UID}:${NB_GID} /home/${NB_USER} \
    && chmod 755 /home/${NB_USER}

# Runtime conda config: channels, plus env/pkg locations inside the user's home.
COPY configs/.condarc ${CONDA_DIR}/.condarc

# Activate the env for login shells and for Jupyter's terminal windows.
# Activated by full prefix rather than by name: `conda activate notebook` would
# search envs_dirs in order, and a user env of the same name in ~/my-conda-envs
# comes first and would shadow this one.
RUN echo ". ${CONDA_DIR}/etc/profile.d/conda.sh ; conda activate ${NB_PYTHON_PREFIX}" > /etc/profile.d/init_conda.sh \
    && printf '\n. %s/etc/profile.d/conda.sh\nconda activate %s\n' "${CONDA_DIR}" "${NB_PYTHON_PREFIX}" >> /etc/bash.bashrc

# --- jupyter config ----------------------------------------------------------
COPY configs/jupyter_server_config.py /etc/jupyter/jupyter_server_config.py

# --- entrypoint --------------------------------------------------------------
COPY --chmod=755 scripts/start /srv/start

EXPOSE 8888
USER ${NB_USER}

# A default only, for local runs with no HOME set. At runtime scripts/start cds
# to the real $HOME, because Jupyter serves files from the working directory.
WORKDIR ${HOME}

ENTRYPOINT ["/srv/start"]
