# Jupyter server configuration for the CIRRUS single-user image.
#
# Keep this file small. Most behaviour is better set on the hub side, where it
# can be changed without rebuilding every user image.
import os

c = get_config()  # noqa: F821

c.ServerApp.ip = "0.0.0.0"
c.ServerApp.open_browser = False

# Let users see and manage dotfiles in the file browser.
c.ContentsManager.allow_hidden = True

# Deleting a directory should really delete it, rather than quietly filling the
# user's home directory with a hidden trash folder.
c.FileContentsManager.always_delete_dir = True

# Offer svg and pdf as well as raster formats for inline plots.
c.InlineBackend.figure_formats = {"png", "jpeg", "svg", "pdf"}

# nb_conda_kernels lists conda environments as kernels. Filter out this image's
# own environment so it is not listed twice - once as the running kernel and
# again as a discovered env. Built from $CONDA_ENV rather than hardcoded, so
# renaming the environment cannot silently break the kernel list.
c.CondaKernelSpecManager.env_filter = f'.*envs/{os.environ.get("CONDA_ENV", "notebook")}.*'

# Deliberately NOT setting c.MultiKernelManager.default_kernel_name here.
# With a single environment, the default `python3` kernel already IS this
# environment. Pinning the default to a `conda-env-<name>-py` spec breaks the
# moment the environment is renamed, and the breakage is hard to trace because
# this file lives inside the image.

# Honour a umask set by the hub, for group-writable shared directories.
if "NB_UMASK" in os.environ:
    os.umask(int(os.environ["NB_UMASK"], 8))
