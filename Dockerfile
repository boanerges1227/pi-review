ARG IRIS_IMAGE=iris-community:2026.3.0AI.154.0
FROM ${IRIS_IMAGE}
# For local builds only; do not publish EAP-derived images to public registries.
COPY --chown=irisowner:irisowner . /workspace
