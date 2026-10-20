# Kolla's Horizon image with the lab's patches to the dashboards in it.
# Built on every node by ansible/horizon.yml; Kolla deploys it instead of the
# upstream image (horizon_image in globals.yml)
ARG BASE
FROM ${BASE}

COPY patches/ /tmp/patches/

# --forward makes a patch that upstream has since merged fail the build,
# rather than be skipped: that's the sign to drop it from the lab
RUN for p in /tmp/patches/*.patch; do \
      patch --forward --batch -p1 -d /var/lib/kolla/venv/lib/python3/site-packages < "$p" || exit 1; \
    done \
 && rm -rf /tmp/patches
