# Ubuntu 22.04 "jammy" is deliberate, on two counts:
#
#   1. Pushpin publishes apt packages for Ubuntu (and old Debian), but not for
#      Debian bookworm — which is what most devcontainer images are based on.
#   2. Jammy's system Python is 3.10, which is what the Django 3.2 backend
#      inherited from the upstream demo wants. Newer images ship Python 3.12,
#      where Django 3.2 does not run.
FROM mcr.microsoft.com/devcontainers/base:jammy

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pushpin's apt repository only publishes amd64 builds. GitHub Codespaces is
# always x86_64, so this is only hit by someone building the container locally
# on an ARM machine (e.g. an Apple Silicon Mac). Fail loudly and early with an
# actionable message rather than confusingly later.
RUN arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != "amd64" ]; then \
      echo "================================================================" >&2; \
      echo "ERROR: this devcontainer needs amd64; detected '$arch'." >&2; \
      echo "" >&2; \
      echo "Pushpin (which stands in for Fanout locally) only has amd64 apt" >&2; \
      echo "packages. Options:" >&2; \
      echo "  * Open this repo in GitHub Codespaces (always amd64), or" >&2; \
      echo "  * force amd64 emulation locally, e.g. by adding" >&2; \
      echo "      \"runArgs\": [\"--platform=linux/amd64\"]" >&2; \
      echo "    to .devcontainer/devcontainer.json (slow), or" >&2; \
      echo "  * install Pushpin yourself and run the apps outside a container" >&2; \
      echo "    (see README.md -> Running without Codespaces)." >&2; \
      echo "================================================================" >&2; \
      exit 1; \
    fi

# System Python for the Django origin app.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Pushpin: the open-source GRIP proxy that Fastly Fanout is built on. The
# Fastly CLI shells out to this binary so that createFanoutHandoff() works on
# a local machine, with no Fastly account required.
#
# The newest published package sometimes targets a different Ubuntu release
# than the one we're on (its dependencies won't resolve), so if the default
# candidate can't be installed we walk back through older versions until one
# does. This keeps the image building even as upstream publishes new packages.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://pushpin.org/pushpin-package.asc \
        | gpg --dearmor -o /etc/apt/keyrings/pushpin.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/pushpin.gpg] https://packages.pushpin.org/deb pushpin-jammy main" \
        > /etc/apt/sources.list.d/pushpin.list \
    && apt-get update \
    && if ! apt-get install -y --no-install-recommends pushpin; then \
         echo "Newest Pushpin package did not resolve; trying older versions..." >&2; \
         apt-get --fix-broken -y install || true; \
         installed=0; \
         for version in $(apt-cache madison pushpin | awk '{print $3}'); do \
           echo "Trying pushpin=$version" >&2; \
           if apt-get install -y --no-install-recommends "pushpin=$version"; then \
             installed=1; break; \
           fi; \
           apt-get --fix-broken -y install || true; \
         done; \
         [ "$installed" = "1" ]; \
       fi \
    && rm -rf /var/lib/apt/lists/* \
    && command -v pushpin
